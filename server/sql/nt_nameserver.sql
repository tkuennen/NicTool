# vim: set expandtab:
#
# $Id: nt_nameserver.sql,v 1.2 2004/04/03 20:25:49 matt Exp $
#
# Copyright 2001 Dajoba, LLC - <info@dajoba.com>

DROP TABLE IF EXISTS nt_nameserver;
CREATE TABLE nt_nameserver(
    nt_nameserver_id    SMALLINT UNSIGNED AUTO_INCREMENT NOT NULL PRIMARY KEY,
    nt_group_id         INT UNSIGNED NOT NULL,
    name                VARCHAR(127) NOT NULL,
    ttl                 INT UNSIGNED,
    description         VARCHAR(255),
    address             VARCHAR(127) NOT NULL,
    service_type        enum('hosted','data-only') NOT NULL,
    output_format       enum('djb','bind','nt') NOT NULL,
    logdir              VARCHAR(255),
    datadir             VARCHAR(255),
    export_interval     SMALLINT UNSIGNED,
    deleted             enum('0','1') DEFAULT '0' NOT NULL
);
CREATE INDEX nt_nameserver_idx1 on nt_nameserver(name);
CREATE INDEX nt_nameserver_idx2 on nt_nameserver(deleted);

DROP TABLE IF EXISTS nt_nameserver_log;
CREATE TABLE nt_nameserver_log(
    nt_nameserver_log_id    INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    nt_group_id         INT UNSIGNED NOT NULL,
    nt_user_id          INT UNSIGNED NOT NULL,
    action              ENUM('added','modified','deleted','moved') NOT NULL,
    timestamp           INT UNSIGNED NOT NULL,
    nt_nameserver_id    SMALLINT UNSIGNED NOT NULL,
    name                VARCHAR(127),
    ttl                 INT UNSIGNED,
    description         VARCHAR(255),
    address             VARCHAR(127),
    service_type        enum('hosted','data-only'),
    output_format       enum('djb','bind','nt'),
    logdir              VARCHAR(255),
    datadir             VARCHAR(255),
    export_interval     SMALLINT UNSIGNED
);
CREATE INDEX nt_nameserver_log_idx1 on nt_nameserver_log(nt_nameserver_id);
CREATE INDEX nt_nameserver_log_idx2 on nt_nameserver_log(timestamp);

INSERT INTO nt_nameserver(nt_group_id, name, ttl, description, address, service_type,
  output_format, logdir, datadir, export_interval) values (1,'x2.nictool.com.',86400,'ns west',
  '216.133.235.6','hosted','djb','/etc/tinydns-216.133.235.6/log/main/','/etc/tinydns-216.133.235.6/root/',120);
INSERT INTO nt_nameserver(nt_group_id, name, ttl, description, address, service_type,
  output_format, logdir, datadir, export_interval) values (1,'x1.nictool.com.',86400,'ns east',
  '198.93.97.188','hosted','djb','/etc/tinydns-198.93.97.188/log/main/',
  '/etc/tinydns-198.93.97.188/root/',120);
INSERT INTO nt_nameserver_log(nt_group_id,nt_user_id, action, timestamp, nt_nameserver_id) VALUES (1,1,'added',UNIX_TIMESTAMP(), 1);
INSERT INTO nt_nameserver_log(nt_group_id,nt_user_id, action, timestamp, nt_nameserver_id) VALUES (1,1,'added',UNIX_TIMESTAMP(), 2);


DROP TABLE IF EXISTS nt_nameserver_qlog;
CREATE TABLE nt_nameserver_qlog(
    nt_nameserver_qlog_id   INT UNSIGNED AUTO_INCREMENT NOT NULL PRIMARY KEY,
    nt_nameserver_id        SMALLINT UNSIGNED NOT NULL,
    nt_zone_id              INT UNSIGNED NOT NULL,
    nt_zone_record_id       INT UNSIGNED,
    timestamp               INT UNSIGNED NOT NULL,
    ip                      VARCHAR(15),
    port                    SMALLINT UNSIGNED, # remote port query came from
    qid                     SMALLINT UNSIGNED, # query ID passed by remote side
    flag                    CHAR(1), # - means did not provide an answer, + means provided answer (this should always be true)
    qtype                   ENUM('a','ns','cname','soa','ptr','hinfo','mx','txt','rp','sig','key','aaaa','axfr','any','unknown'), 
    query                   VARCHAR(255) NOT NULL, # what they asked for
    r_size                  SMALLINT UNSIGNED,
    q_size                  SMALLINT UNSIGNED
);
CREATE INDEX nt_nameserver_qlog_idx1 on nt_nameserver_qlog(query); # for searching
CREATE INDEX nt_nameserver_qlog_idx2 on nt_nameserver_qlog(nt_zone_id); # for search as well
CREATE INDEX nt_nameserver_qlog_idx3 on nt_nameserver_qlog(nt_zone_record_id); # for searching ..
CREATE INDEX nt_nameserver_qlog_idx4 on nt_nameserver_qlog(timestamp); 

DROP TABLE IF EXISTS nt_nameserver_qlogfile;
CREATE TABLE nt_nameserver_qlogfile(
    nt_nameserver_qlogfile_id      INT UNSIGNED AUTO_INCREMENT NOT NULL PRIMARY KEY,
    nt_nameserver_id               INT UNSIGNED NOT NULL,
    filename                    VARCHAR(30) NOT NULL,
    processed                   INT UNSIGNED,
    line_count                  INT UNSIGNED,
    insert_count                INT UNSIGNED,
    took                        SMALLINT UNSIGNED
);
CREATE INDEX nt_nameserver_qlogfile_idx1 on nt_nameserver_qlogfile(filename); # for search from grab_logs.pl
CREATE INDEX nt_nameserver_qlogfile_idx2 on nt_nameserver_qlogfile(nt_nameserver_id); # for searching

DROP TABLE IF EXISTS nt_nameserver_export_log;
CREATE TABLE nt_nameserver_export_log(
    nt_nameserver_export_log_id     INT UNSIGNED AUTO_INCREMENT NOT NULL PRIMARY KEY,
    nt_nameserver_id                SMALLINT UNSIGNED NOT NULL,
    date_start                      INT UNSIGNED NOT NULL,
    date_finish                     INT UNSIGNED,
    stat1                           SMALLINT UNSIGNED, # DJB: time to dump data
    stat2                           SMALLINT UNSIGNED, # time to build cdb
    stat3                           SMALLINT UNSIGNED, # time to rsync
    stat4                           SMALLINT UNSIGNED, # size of data ?
    stat5                           SMALLINT UNSIGNED, # size of data.cdb ?
    stat6                           SMALLINT UNSIGNED,
    stat7                           SMALLINT UNSIGNED,
    stat8                           SMALLINT UNSIGNED,
    stat9                           SMALLINT UNSIGNED
);
CREATE INDEX nt_nameserver_export_log_idx1 on nt_nameserver_export_log(nt_nameserver_id);

DROP TABLE IF EXISTS nt_nameserver_export_procstatus;
CREATE TABLE nt_nameserver_export_procstatus(
    nt_nameserver_id                SMALLINT UNSIGNED NOT NULL PRIMARY KEY,
    timestamp                       INT UNSIGNED NOT NULL,
    status                          VARCHAR(255)
);
