package NicToolServer::Export;
# ABSTRACT: export DNS data to authoritative DNS servers

use strict;
use warnings;

use Cwd;
use Data::Dumper;
use DBIx::Simple;
use File::Path;
use Params::Validate qw/ :all /;

use lib 'lib';
use NicToolServer::Export::tinydns;
use NicToolServer::Export::BIND;

# this class and subclasses support nt_export.pl
# subclasses (see tinydns & BIND ^^) have logic to export to them

sub new {
    my $class = shift;
    my %p     = validate(
        @_,
        {   ns_id => { type => SCALAR },
            debug => { type => BOOLEAN, optional => 1 },
            force => { type => BOOLEAN, optional => 1 },
        }
    );

    return bless {
        ns_id  => $p{ns_id},           # current nameserver ID
        force  => $p{force},
        dbix_r => undef,
        dbix_w => undef,
        debug  => defined $p{debug} ? $p{debug} : 0,
        export_class => undef,
        export_dir => undef,
        export_format => 'tinydns',
        export_required => 1,
        export_serials => undef,       # export serials for this nsid?
        log_id         => undef,       # current log ID
        active_ns_ids  => undef,       # nsids for a zone
        ns_ref => undef,
        time_start => time,
        dir_orig => Cwd::getcwd,
        },
        $class;
}

sub daemon {
    my $self = shift;
    $self->export();
    my $end = time;
    my $waitleft = 60;
    if ( defined $self->{ns_ref}{export_interval} ) {
        $waitleft = $self->{ns_ref}{export_interval} - ( $end - $self->{time_start} );
    };
    if ( $waitleft > 0 ) {
        print ", sleeping $waitleft seconds\n";
        sleep $waitleft;
    };
};

sub elog {
    my $self    = shift;
    my $message = shift;
    my %p       = validate(
        @_,
        {   success => { type => BOOLEAN, optional => 1 },
            partial => { type => BOOLEAN, optional => 1 },
        }
    );
    my $logid = $self->get_log_id();
    my $sql = "UPDATE nt_nameserver_export_log 
    SET message=CONCAT_WS(', ',message,?)";

    my @args = $message;
    foreach (qw/ success partial /) {
        if ( defined $p{$_} ) {
            $sql .= ",$_=?";
            push @args, $p{$_};
        }
    }

    push @args, $self->{ns_id}, $logid;
    $sql .= "WHERE nt_nameserver_id=? AND nt_nameserver_export_log_id=?";
    $self->exec_query( $sql, \@args );
    print ", $message";
    return $message;
}

sub set_status {
    my $self    = shift;
    my $message = shift;
    my $sql = "UPDATE nt_nameserver SET export_status=?  WHERE nt_nameserver_id=?";
    $self->exec_query( $sql, [ $message, $self->{ns_id} ] );
}

sub exec_query {
    my $self = shift;
    my ( $sql, $params, $extra ) = @_;

    my @caller = caller;
    my $err
        = sprintf( "exec_query called by %s, %s\n", $caller[0], $caller[2] );
    $err .= "\t$sql\n\t";

    die "invalid arguments to exec_query!" if $extra;

    my @params;
    if ( defined $params ) {    # dereference $params into @params
        @params = ref $params eq 'ARRAY' ? @$params : $params;
        $err .= join( ', ', @params ) . "\n";
    }

    warn $err if $self->{debug};
    my $dbix_r = $self->{dbix_r};
    my $dbix_w = $self->{dbix_w};

    if ( $sql =~ /^INSERT INTO/ ) {
        my ($table) = $sql =~ /INSERT INTO (\w+)[\s\(]/;
        eval { $dbix_w->query( $sql, @params ); };
        if ( $@ or $dbix_w->error ne 'DBI error: ' ) {
            warn $err . $dbix_w->error if $self->{debug};
            return;
        }
        return $dbix_w->last_insert_id( undef, undef, $table, undef );

        # don't test the value of last_insert_id. If the table doesn't have an
        # autoincrement field, the value is always zero
    }
    elsif ( $sql =~ /^DELETE|UPDATE/ ) {
        eval { $dbix_w->query( $sql, @params ) };
        if ( $@ or $dbix_w->error ne 'DBI error: ' ) {
            warn $err . $dbix_w->error if $self->debug;
            return;
        }
        return $dbix_w->query("SELECT ROW_COUNT()")->list;
    }

    my $r;
    eval { $r = $dbix_r->query( $sql, @params )->hashes; };
    warn "$err\t$@" if $@;    #&& $self->{debug} );
    return $r;
}

sub export {
    my $self = shift;

    $self->preflight or return;
    $self->get_active_nameservers;

    if ( ! $self->{export_required} && ! $self->{force} ) {
        $self->set_status("no changes.");
        $self->elog("exiting");
        return;
    };
    $self->set_status("exporting from DB");

    my $fh;
    foreach my $z ( @{ $self->get_ns_zones() } ) {
        $fh = $self->{export_class}->get_export_file( 
            $self->get_export_dir, $z->{zone} ) 
                or die "unable to figure out export name for zone $z->{zone}\n";
        $self->{zone_name} = $z->{zone};
        print $fh $self->zr_soa( zone => $z );
        print $fh $self->zr_ns( zone => $z );
        my $records = $self->get_zone_records( zone => $z );
        $self->zr_dispatch( zone => $z, records => $records, fh=>$fh );
        close $fh if $self->{export_format} eq 'bind';
    }
    close $fh if $self->{export_format} eq 'tinydns';

# TODO: detect and delete BIND zone files deleted in NicTool
    $self->elog("exported");
    $self->postflight or return;
    return 1;
}

sub get_dbh {
    my $self = shift;
    my %p    = validate(
        @_,
        {   dsn    => { type => SCALAR },
            user   => { type => SCALAR },
            pass   => { type => SCALAR },
            dsn_w  => { type => SCALAR, optional => 1 },
            user_w => { type => SCALAR, optional => 1 },
            pass_w => { type => SCALAR, optional => 1 },
        }
    );

   # get database handles (r/w and r/o)
   #
   # the read handle is the default handle. If a second write DSN is provided,
   # it is used for INSERT/UPDATE/DELETE queries. This is useful for sites
   # with one-way replicated database servers with a local db slave.

    die "invalid DSN! ($p{dsn})" if $p{dsn} !~ /^DBI/;

    $self->{dbix_r} = DBIx::Simple->connect( $p{dsn}, $p{user}, $p{pass} )
        or die DBIx::Simple->error;

    $self->{dbix_w} = DBIx::Simple->connect(
        $p{dsn_w}  || $p{dsn},
        $p{user_w} || $p{user},
        $p{pass_w} || $p{pass}
    ) or die DBIx::Simple->error;
    return $self->{dbix_r};
}

sub get_export_dir {
    my $self = shift;

    return $self->{export_dir} if $self->{export_dir};

    $self->get_active_nameservers();  # populate $self->{ns_ref}

    my $dir;

    if ( defined $self->{ns_ref}{datadir} ) {

        # try the directory defined in nt_nameserver.datadir
        $dir = $self->{ns_ref}{datadir};
        if ( $dir && -d $dir ) {
            if ( -w $dir && ( ! -e "$dir/data" || -w "$dir/data" ) ) {
                $self->{export_dir} = $dir;
                #$self->elog("using $dir");
                return $dir;
            };
            $self->elog("export dir ($dir) not writable");
        };

        # try the local working directory
        $dir = getcwd . '/data-' . $self->{ns_ref}{name};
        $dir =~ s/\.$//;   # strip off any trailing dot
        if ( -d $dir ) {
            if ( -w $dir ) {
                #$self->elog("using $dir");
                $self->{export_dir} = $dir;
                return $dir;
            };
            $self->elog("export dir ($dir) not writable");
            return;
        }
    }
    else {
        $dir = getcwd . '/data-all';  # special nsid = 0 (all) specified
        if ( -d $dir ) {
            $self->{export_dir} = $dir;
            return $dir;
        };
    };

    eval { mkpath( $dir, { mode => 0755 } ); };
    if ( -d $dir ) {     # mkpath just created it
        $self->elog("created $dir");
        $self->{export_dir} = $dir;
        return $dir;     # I have write permission
    };
    $self->elog("unable to create dir ($dir): $@");
    return;
};

sub get_last_ns_export {
    my $self = shift;
    my %p    = validate(
        @_,
        {   success => { type => BOOLEAN, optional => 1 },
            partial => { type => BOOLEAN, optional => 1 },
        }
    );

    my $sql = "SELECT nt_nameserver_export_log_id AS id, 
        date_start, date_end, message
      FROM nt_nameserver_export_log
        WHERE nt_nameserver_id=?";

    my @args = $self->{ns_id};
    foreach my $f (qw/ success partial /) {
        if ( defined $p{$f} ) {
            $sql .= " AND $f=?";
            push @args, $p{$f};
        }
    }

    $sql .= " ORDER BY date_start DESC LIMIT 1";

    my $logs = $self->exec_query( $sql, \@args );
    my $message = "no previous export";
    $message = "no previous successful export" if defined $p{success} && $p{success} == 1;
    $self->elog( $message ) if scalar @$logs == 0;
    return $logs->[0];
}

sub get_ns_id {
    my $self = shift;
    my %p    = validate(
        @_,
        {   id   => { type => SCALAR, optional => 1 },
            name => { type => SCALAR, optional => 1 },
            ip   => { type => SCALAR, optional => 1 },
        }
    );

    die "An id, ip, or name must be passed to get_ns_id\n"
        if ( !$p{id} && !$p{name} && !$p{id} );

    my @args;
    my $sql = "SELECT nt_nameserver_id AS id FROM nt_nameserver 
        WHERE deleted=0";

    if ( defined $p{id} ) {
        $sql .= " AND nt_nameserver_id=?";
        push @args, $p{id};
    }
    if ( defined $p{ip} ) {
        $sql .= " AND address=?";
        push @args, $p{ip};
    }
    if ( defined $p{name} ) {
        $sql .= " AND name=?";
        push @args, $p{name};
    }

    my $nameservers = $self->exec_query( $sql, \@args );
    return $nameservers->[0]->{id};
}

sub get_ns_zones {
    my $self = shift;
    my %p = validate( @_,
        { last_modified => { type => SCALAR, optional => 1 }, },
        );

    my $sql = "SELECT z.nt_zone_id, z.zone, z.mailaddr, z.serial, z.refresh,
        z.retry, z.expire, z.minimum, z.ttl, z.location, z.last_modified
FROM nt_zone z";

# TODO: It may prove faster to collect the NSIDs now, similar to how the old 
# nt_export_djb.c app did. But I'll save optimization for when it's necessary
# because premature optimization is the root of all evil... If we did want to,
# something like this would do it:
# (SELECT GROUP_CONCAT(nt_nameserver_id) FROM nt_zone_nameserver n WHERE
# n.nt_zone_id=z.nt_zone_id) AS nsids

    my @args;
    if ( $self->{ns_id} == 0 ) {
        $sql .= " WHERE z.deleted=0";  # all zones, regardless of NS pref
    }
    else {
        $sql .= "
  LEFT JOIN nt_zone_nameserver n ON z.nt_zone_id=n.nt_zone_id
    WHERE n.nt_nameserver_id=? AND z.deleted=0";
        push @args, $self->{ns_id};
    }

    if ( $p{last_modified} ) {
        $sql .= " AND z.last_modified > ?";
        push @args, $p{last_modified};
    }

    my $r = $self->exec_query( $sql, \@args ) or return [];
    $self->elog( "retrieved " . scalar @$r . " zones" );
    return $r;
}

sub get_log_id {
    my $self = shift;
    my %p    = validate(
        @_,
        {   success => { type => BOOLEAN, optional => 1 },
            partial => { type => BOOLEAN, optional => 1 },
        }
    );
    return $self->{log_id} if defined $self->{log_id};
    my $message = "started";
    my $sql   = "INSERT INTO nt_nameserver_export_log 
        SET nt_nameserver_id=?, date_start=CURRENT_TIMESTAMP(), message=?";

    my @args = ( $self->{ns_id}, $message );
    foreach (qw/ success partial /) {
        if ( defined $p{$_} ) {
            $sql .= ",$_=?";
            push @args, $p{$_};
        }
    }

    $self->{log_id} = $self->exec_query( $sql, \@args );
    return $self->{log_id};
}

sub get_modified_zones {
    my $self = shift;
    my %p = validate( @_, { since => { type => SCALAR | UNDEF, optional => 1 }, } );

    my $sql = "SELECT COUNT(*) AS count FROM nt_zone z WHERE 1=1";
    my @args;

    if ( defined $self->{ns_id} && $self->{ns_id} != 0 ) {
        $sql = "SELECT COUNT(*) AS count FROM nt_zone_nameserver zn
        LEFT JOIN nt_zone z ON zn.nt_zone_id=z.nt_zone_id
        WHERE zn.nt_nameserver_id=?";
        @args = $self->{ns_id};
    };

    if ( defined $p{since} ) {
        $sql .= " AND z.last_modified>?";
        push @args, $p{since};
    };

    my $r = $self->exec_query( $sql, \@args );
    return $r->[0]{count};
}

sub get_zone_ns_ids {
    my $self = shift;
    my $zone = shift or die "missing zone";
    ref $zone or die "invalid zone object";

    return $self->{dbix_r}->query(
        "SELECT zn.nt_nameserver_id 
          FROM nt_zone_nameserver zn
            LEFT JOIN nt_nameserver n ON zn.nt_nameserver_id=n.nt_nameserver_id
                WHERE zn.nt_zone_id=? AND n.deleted=0",
        $zone->{nt_zone_id}
    )->flat;
}

sub get_zone_records {
    my $self = shift;
    my %p = validate( @_, { zone => { type => HASHREF } } );

    my $zid = $p{zone}->{nt_zone_id};
    my $sql = "SELECT name, ttl, description, type, address, weight, 
    priority, other, location, UNIX_TIMESTAMP(timestamp) AS timestamp
        FROM nt_zone_record
         WHERE deleted=0 AND nt_zone_id=?";

    return $self->exec_query( $sql, $zid );
}

sub get_active_nameservers {
    my $self = shift;
    return $self->{active_ns} if defined $self->{active_ns};

    my $sql = "SELECT * FROM nt_nameserver WHERE deleted=0 
        ORDER BY nt_nameserver_id";
    $self->{active_ns} = $self->exec_query($sql);    # populated

    foreach my $r ( @{ $self->{active_ns} } ) {
        $self->{active_ns_ids}{ $r->{nt_nameserver_id} } = $r;

        # tinydns can autogenerate serial numbers based on data file
        # timestamp. Export serials for everyone else.
        $r->{export_serials}++ if $r->{export_format} ne 'tinydns';
    }

    #warn Dumper( $self->{active_ns} );
    my $export_format;
    if ( $self->{ns_id} ) {
        $self->{ns_ref} = $self->{active_ns_ids}{$self->{ns_id}};
        $self->{export_format} = $self->{ns_ref}{export_format};
    }
    else {
        my $first = $self->{active_ns_ids}{ $self->{active_ns}[0] };
        $self->{export_format} = $first->{export_format} if $first->{export_format};
    };

    if ( $self->{export_format} eq 'bind' ) {
        $self->{export_class} = NicToolServer::Export::BIND->new( $self );
    }
    else {
        $self->{export_class} = NicToolServer::Export::tinydns->new( $self );
    };
    return $self->{active_ns};
}

sub preflight {
    my $self = shift;

    return 1 if $self->{export_required} == 0; # already called

# TODO: test when last export attempted. If less than export_interval seconds,
# sleep until ready. This will prevent a rightously zealous init/supervise
# program from causing a vicious loop. Allow override with -force on the 
# command line.

    $self->get_log_id;

    # bail out if no export required
    #    get timestamp of last successful export
    my $export = $self->get_last_ns_export( success => 1 );
    if ( $export ) {
        my $ts_success = $export->{date_start};
        if ( $ts_success ) {
# do any zones for this nameserver have updates more recent than last successful export?
            my $c = $self->get_modified_zones( since => $ts_success );
            $self->{export_required} = 0 if $c == 0;
            $self->elog("$c changed zones");
        };
    };
    $self->elog("export required") if $self->{export_required};

    # determine export directory
    $self->get_export_dir or return;
    return 1;
}

sub postflight {
    my $self = shift;

    $self->{export_class}->postflight or return;

    $self->update_status();

    $self->write_runfile();

    # mark export successful
    $self->elog("complete", success=>1);
}

sub update_status {
    my $self = shift;
    my $run_time = time - $self->{time_start};
    my $waitleft = $self->{ns_ref}{export_interval} - $run_time;
    if ( $run_time < $self->{ns_ref}{export_interval} ) {
        my $tstring = localtime( $self->{time_start} + $run_time + $waitleft );
        $tstring = substr( $tstring, 4, 15 );
        $self->set_status( "last:SUCCESS, next:$tstring" );
    }
    else {
        $self->set_status( "last: SUCCESS" );
    };
};

sub write_runfile {
    my $self = shift;

    chdir $self->{dir_orig};
    return if -f 'run';
    open my $F, '>', 'run' or return;
    print $F <<EORUN
#!/bin/sh
#
# direct STDERR to STDOUT
exec 2>&1
#
# if run file is started by something like init, upstart, or daemontools,
# setuidgid to the 'nictool' user, and run the export, logging to syslog.
#exec setuidgid nictool ./nt_export.pl -nsid $self->{ns_id} -daemon | logger
#
# if run by cron, at, or interactively by a human who is logged in as the
# 'nictool' user, this will work well. The -force option is included because
# odds are, if you are running this by hand, you'll want the export to be
# triggered, regardless of any DB changes.
exec ./nt_export.pl -nsid $self->{ns_id} -force
EORUN
;
    close $F;
    CORE::chmod( oct('0755'), 'run' );
};

sub zr_soa {
    my $self = shift;
    my %p = validate( @_, { zone => { type => HASHREF } } );

    my $z  = $p{zone};

    my @ns_ids       = $self->get_zone_ns_ids( $z );
    $z->{timestamp}  = '';       # does it make sense to?
    $z->{location} ||= '';
    $z->{nsname}     = $self->{active_ns_ids}{ $ns_ids[0] }{name};
    $z->{serial}     = $self->{ns_ref}{export_serials} ? $z->{serial} : '',

    my $r = $self->{export_class}->zr_soa( zone => $z );
    return $r;
}

sub zr_ns { 
    my $self = shift;
    my %p = validate( @_, { zone => { type => HASHREF } } );

    my $z = $p{zone};
    my $r;
    foreach my $nsid ( $self->get_zone_ns_ids( $z ) ) {
        my $ns_ref = $self->{active_ns_ids}{$nsid};
        $r .= $self->{export_class}->zr_ns(
            record => {
                name     => $z->{zone},
                address  => $self->qualify( $ns_ref->{name}, $z->{zone} ),
                ttl      => $ns_ref->{ttl},
                location => $self->{ns_ref}{location} || '',
                timestamp => '',
            },
        );
    }
    return $r;
}

sub zr_dispatch {
    my $self = shift;
    my %p    = validate(
        @_,
        {   zone    => { type => HASHREF  },
            records => { type => ARRAYREF },
            fh      => { type => HANDLE   },
        }
    );

    my $FH = $p{fh};
    foreach my $r ( @{ $p{records} } ) {
        my $type   = lc( $r->{type} );
        my $method = "zr_${type}";
        $r->{location}  ||= '';
        $r->{timestamp} = $r->{timestamp} ? $self->{export_class}->format_timestamp($r->{timestamp}) : '';
        print $FH $self->{export_class}->$method( record => $r );
    }
}

sub is_ip_port {
    my ( $self, $port ) = @_;

    return $port if ( $port >= 0 && $port <= 65535 );
    warn "value not within IP port range: 0 - 65535";
    return 0;
}

sub qualify {
    my ( $self, $record, $zone ) = @_;
    return $record if $record =~ /\.$/;    # record already ends in .
    $zone ||= $self->{zone_name} or return $record;
    return $record if $record =~ /$zone$/;    # ends in zone, just no .
    return "$record.$zone"                    # append missing zone name
}


1;

__END__

