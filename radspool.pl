#!/bin/perl
# Copyright (C) 2019 Christian Meutes <christian.meutes@errxtx.net>
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# 1. Redistributions of source code must retain the above copyright notice,
# this list of conditions and the following disclaimer.
#
# 2. Redistributions in binary form must reproduce the above copyright notice,
# this list of conditions and the following disclaimer in the documentation
# and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
# LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.
#
#
# radspool - More of a concept than technically anything advanced, this design
#            favors the use of storing the ongoing RADIUS accounting data stream
#            as JSON formatted object files in a directory serving as the
#            accounting buffer spool on the RADIUS host. radspool sends the data
#            out of this spool in frequent intervals to the final backend.
#            With this approach accounting data won't get lost when the RADIUS
#            server is eg. simply undergoing a maintenance of very few minutes
#            of an outage. All accounting records encapsulated in JSON in a file
#            need to be committed to the backend before the file becomes
#            deleted. That's because a single SQL transaction is used for all
#            records of a JSON file. If something within that process goes
#            wrong a SQL rollback will be made and all previous SQL operations
#            which were created from that file will be undone/non-committed.
#           
# The idea behind this script is to store accounting data first on the local
# filesystem of the Radiator host before it's going to be further processed and
# finally put into the SQL/DB backend. By having filesystem level access on the
# JSON formatted data, other applications can easily have access and participate
# as well (eg. exporting into ElasticSearch)
#
# This script parses these accounting files and inserts them into a configured
# SQL backend. If the SQL backend is non-functional, cannot be accessed, has
# any certain issue that leads to an exception, it will SQL rollback if needed
# (single transaction is started on each accounting file) and a final commit is
# omitted. If all inserts succeeded, then the file containing the data for those
# inserts is deleted at the end as well.
#
# In case of issue, the accounting file containing the data will not be deleted
# instead it will remain where it is and radspool on it's next execution
# (eg. cron) will try to insert the contained data again. $SPOOLDIR will grow
# in that case by one new accounting file - each time the script is run, the
# most recent and active 'acctlog-combined.json' file will be moved into the
# spool directory. In certain situations it might be beneficial to have the
# flexibility to configure the scope of the transaction. In high volume setups
# with large log files, small transactions could reduce storage usage in
# certain situations by being able to commit inserts not affected by the failed
# operation. In other setups it's probably much more likely that you want to
# optimize for CPU and IO. Depending on the individual problem, some
# configuration knobs would be useful to have.
#
# (this code does basically ..
# 1. move current active JSON accounting file to $SPOOLDIR
# 2. build array of files from $SPOOLDIR and loop through
# 3. open next file, parse it's JSON, prepare SQL insert with the new data
# 4. on any exception in any previous step do a SQL rollback and skip file
# 5. do a SQL commit and delete the file
# )

use strict;
use warnings;

use JSON::XS;
use DBI;
use File::Copy;
use Time::HiRes qw(time);
use POSIX qw(strftime);
use Fcntl qw(:flock);
use Syntax::Keyword::Try;

# Modify next block to suit your needs

# JSON formatted accounting file
my $ACCTFILE = '/var/log/radius/accounting/sql/acctlog-combined.json';
# On execution $ACCTFILE is moved to $SPOOLDIR and all files in that directory
# are considered as candidates to be inserted into SQL
my $SPOOLDIR  = '/var/log/radius/accounting/sql/spool/';
my $DBHOST   = 'yourhost';
my $DBPORT   =  3306;
my $DBDRIVER = 'mysql';
my $DBNAME   = 'yourdbname';
my $DBUSER   = 'youruser';
my $DBPASS   = 'yourpass';
my $DBTABLE  = 'yourtable';

# JSON to SQL schema mapping table Hash-key is the attribute found in the JSON
# file. Hash-value contains the SQL column name.  Modify this hash to your
# needs so that it matches with your environment.
my %MAPPING = (
    username               => 'USERNAME',
    username_nas           => 'USERNAMENAS',
    timestamp              => 'TIME_STAMP',
    acct_status_type       => 'ACCTSTATUSTYPE',
    acct_delay_time        => 'ACCTDELAYTIME',
    acct_input_octets      => 'ACCTINPUTOCTETS',
    acct_output_octets     => 'ACCTOUTPUTOCTETS',
    acct_session_id        => 'ACCTSESSIONID',
    acct_session_time      => 'ACCTSESSIONTIME',
    acct_terminate_cause   => 'ACCTTERMINATECAUSE',
    framed_ip_address      => 'FRAMEDIPADDRESS',
    framed_ipv6_address    => 'FRAMEDIPV6ADDRESS',
    framed_protocol        => 'FRAMEDPROTOCOL',
    nas_identifier         => 'NASIDENTIFIER',
    nas_port_type          => 'NASPORTTYPE',
    nas_port               => 'NASPORT',
    dnis                   => 'DNIS',
    calling_station_id     => 'CALLINGSTATIONID',
    called_station_id      => 'CALLEDSTATIONID',
    service_type           => 'SERVICETYPE',
    airespace_wlan_id      => 'AIRESPACEWLANID',
);

# Lock the script so that only once instance is able to run
open our $script, '<', __FILE__ or die "FATAL: Cannot open radspool file (ourself): $!\n";
flock $script, LOCK_EX|LOCK_NB or die "FATAL: Unable to lock file, another instance is probably running: $!\n";

# Move current accounting file to $SPOOLDIR
my $time = time;
my $date = strftime "%Y%m%d%H%M%S", localtime $time;
$date .= sprintf "%03d", ($time-int($time))*1000; # without rounding
move($ACCTFILE,$SPOOLDIR."/acctlog.json.".$date) or
    print "INFO: No new '$ACCTFILE' accounting file or permissions wrong\n";

# Open directory and build the array of files
opendir(DIR, $SPOOLDIR) or die "FATAL: Could not open spool directory '$SPOOLDIR'\n";
my @files = grep { -f $SPOOLDIR.$_ } readdir(DIR);
closedir(DIR);
die "INFO: $SPOOLDIR is empty\n" unless @files;

# Create db handle once, single connection
my $dsn = "dbi:$DBDRIVER:$DBNAME:$DBHOST:$DBPORT";
my $dbh = DBI->connect($dsn, $DBUSER, $DBPASS, {
    RaiseError => 1,
});

# Loop through files, catch exceptions
foreach my $filename (@files) {
    my @data;
    my $file = $SPOOLDIR.$filename;
    try {

        # Decode the JSON file, each line is one accounting record
        open(my $fh, '<', $file) or
            do { print "WARN: Could not open '$file' in '$SPOOLDIR': $!\n"; next };
        while (my $line = <$fh>) {
            my $json_data = decode_json($line);
            my %mapped = map { ($MAPPING{$_} => $json_data->{$_}//'') } keys %MAPPING;
            push @data, \%mapped;
        }
        close($fh);

        # Start SQL transaction
        $dbh->begin_work;
        my $sth;
        for my $row (@data) {
            my $placeholders = join ',', ('?')x(keys %MAPPING);
            my @insert_values = @{$row} { sort keys %{$row} };
            my $insert_cols = join ',', map { $dbh->quote_identifier($_) } sort values %MAPPING;
            my $insert = "INSERT INTO `$DBTABLE` ($insert_cols) VALUES ($placeholders)";
            $sth = $dbh->prepare($insert);
            $sth->execute(@insert_values);
        }

        # Try to commit and delete the file if no exception was thrown so far
        $dbh->commit();
        unlink $file;
    }

    # Exception handling, rollback in case of issues and keep accounting file
    catch {
        print "WARN: Something went wrong: $@\nDoing $DBDRIVER rollback\n";
        $dbh->rollback;
    }
}

$dbh->disconnect;

