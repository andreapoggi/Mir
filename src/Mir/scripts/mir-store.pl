#!/usr/bin/env perl 
#===============================================================================
#
#         FILE: mir-config-reset.pl
#
#        USAGE: ./mir-store.pl  --host <host> 
#                               --port <port> 
#                               --db <database> 
#                               --collection <collection> 
#                               --doc <doc> 
#                               [--append] 
#                               [--find]
#
#  DESCRIPTION: an helper script to handle MIR stores on MongoDB
#
#      OPTIONS: ---
# REQUIREMENTS: ---
#         BUGS: ---
#        NOTES: ---
#       AUTHOR: Marco Masetti
# ORGANIZATION: 
#      VERSION: 1.0
#      CREATED: 08/04/2015 11:33:19 AM
#     REVISION: ---
#===============================================================================
use strict;
use warnings;
use MongoDB;
use Getopt::Long;
use Data::Printer;
use JSON;

my $host        = 'localhost';
my $port        = 27017;
my $db          = 'MIR-CONFIG';
my $collection  = 'mir-system';
my $append      = 0;
my $find        = 0;
my $doc;
my $filename;

die "Usage: $@ --host <host> --port <port> --db <database> --collection <collection> --doc <json> [--append] [--find]\n"
 unless @ARGV;

GetOptions(
    "host=s"        => \$host,
    "port=s"        => \$port,
    "db=s"          => \$db,
    "collection=s"  => \$collection,
    "doc=s"         => \$doc,
    "import-file=s" => \$filename,
    "append"        => \$append,
    "find"          => \$find,
) or die ("Error in command line arguments\n");

print "Going to connect to $host : $port ...\n";
print "Going to connect to database $db, collection $collection  ...\n";

my $client     = MongoDB::MongoClient->new(host => $host, port => $port)
    or die "Error getting a MongoDB::MongoClient object\n";
my $database   = $client->get_database( $db )
    or die "Error connecting to database $db\n";
my $ch = $database->get_collection( $collection );

if ( $find ) {
    my $cursor = $ch->find();
    while ( my $doc = $cursor->next ) {
        p $doc;
    }
}

my $id;

if ( defined $doc ) {
    $id = insert( $doc );
    print "Doc $id added!\n";
}

if ( defined $filename ) {
    {
        local $/;
        die "File $filename seems not existing..." unless -f $filename;
        open ( my $fh, "<", $filename ) or die "Error opening $filename";
        $doc = <$fh>;
        close $fh;
    }

    $id = insert( $doc );
    print "Doc $id added!\n";
    
}

sub insert {
    my $doc = shift;
    my $obj = decode_json( $doc );
    print "Going to insert doc:\n";
    p $obj; print "\n";
    my $id = $ch->insert( $obj ) or die "Error inserting doc $doc\n";
    return $id;
}
