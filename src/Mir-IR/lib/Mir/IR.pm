package Mir::IR;
#============================================================= -*-perl-*-

=head1 NAME

Mir::IR - frontend for the Elastic Search indexer.

=head1 VERSION

0.06

=cut

#HISTORY
# 0.05 | 26.02.2016 | Decoding abspath from utf8 octets to characters....
# 0.06 | 17.03.2016 | Mean confidence added to store after indexing doc...
our $VERSION = '0.06';

=head1 SYNOPSIS

    use Mir::IR ();

    my $ir = Mir::IR->new(
        campaign      => $campaign,
        config_driver => $config_driver,     # Mongo by default...
        config_params => $config_params_json
    );

    # config objects and create Elastic index (if not exists)...
    # (see Mir::Config IR section in system collection)
    $ir->config();

    # consumes all items in queue
    # for each document profile, get document text 
    # and index it
    $ir->process_items_in_queue();

=head1 DESCRIPTION

This class extends the base Search::Elasticsearch to provides utility methods.

=head1 AUTHOR

Marco Masetti (marco.masetti @ softeco.it )

=head1 LICENCE AND COPYRIGHT

Copyright (c) 2015 Marco Masetti (marco.masetti at softeco.it). All rights reserved.

This module is free software; you can redistribute it and/or
modify it under the same terms as Perl itself. See perldoc perlartistic.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

=head1 SUBROUTINES/METHODS

=cut

#========================================================================
use Moose;
use Search::Elasticsearch;
use namespace::clean;
use Log::Log4perl;
use Queue::Q::ReliableFIFO::Redis ();
use Log::Log4perl           qw( :easy );
use Data::Dumper            qw( Dumper );
use TryCatch;
use JSON;
use Mir::Config::Client ();
use Mir::Util::DocHandler ();
use Mir::Doc;
use Mir::Doc::File;
use Mir::Stat;
use Encode;

use vars qw( 
    $log 
    $stat
    $drivers_lut
    $confidence_threashold
    $index
    $type
    $e
);

$log = Log::Log4perl->get_logger( __PACKAGE__ );
{
    local $/;
    my $data=<DATA>;
    $drivers_lut = decode_json $data;
}

has 'campaign'      => ( is => 'rw', isa => 'Str', required => 1 );

# params to get a Mir::Config obj...
has 'config_driver' => ( is => 'rw', isa => 'Str', default => sub { return 'Mongo' } );
has 'config_params' => ( is => 'rw', isa => 'HashRef' );
has 'config_params_json' => ( is => 'rw', isa => 'Str' );
has 'queue'         => ( is => 'rw', isa => 'Queue::Q::ReliableFIFO::Redis' );

#=============================================================

=head2 config

=head3 INPUT

=head3 OUTPUT

=head3 DESCRIPTION

Configure the object.
Configuration is handled by Mir::Config.
The method uses a Mir::Config::Client object to get the 
configuration. Usually, by default, this means accessing
the system collection of the MIR Mongo database...

=cut

#=============================================================
sub config {
    my $self = shift;

    $self->config_params( decode_json( $self->config_params_json ) ) 
        if ( $self->config_params_json );

    my $c = Mir::Config::Client->create( 
        driver => $self->config_driver,
        params => $self->config_params
    ) or die "No Mir::Config::Client object...\n";
    
    $c->connect() or die "Error connecting to a Mir::Config data store\n";
    my $params = $c->get_key({
            tag         => 'IR',
            campaign    => $self->campaign,
        },
        {
            idx_queue_params => 1,
            idx_server       => 1,
            doc_handlers_lut => 1,
            confidence_threashold => 1
        }
    )->[0];

    $log->debug("Going to connect to idx queue:");
    $log->debug( Dumper $params->{idx_queue_params} );
    $log->debug("Going to connect to Search Text Engine:");
    $log->debug( Dumper $params->{idx_server}->{ir_params} );

    $index = $params->{idx_server}->{index};
    $type  = $params->{idx_server}->{type};
    $log->info("Going to index docs of type $type into index $index");

    $log->info("Opening queue:");
    $log->info( Dumper $params->{idx_queue_params} );

    $self->queue( Queue::Q::ReliableFIFO::Redis->new( %{ $params->{idx_queue_params} } ) )
        or die "Error getting a Queue::Q::ReliableFIFO::Redis object\n";

    $log->debug("Getting a Search::Elasticsearch object with params:");
    $log->debug( Dumper $params->{idx_server}->{ir_params} );
    $e = Search::Elasticsearch->new( %{ $params->{idx_server}->{ir_params} } );

    $log->debug( "Getting a Mir::Stat object for counter $self->{campaign}" );
    $stat = Mir::Stat->new(
        counter => $self->{campaign}.'_indexed',
        select  => 10,
    );

    $drivers_lut = $params->{doc_handlers_lut} if ( $params->{doc_handlers_lut} );
    # if no threashold defined we take everything...
    $confidence_threashold = $params->{confidence_threashold} || 0; 
}

#=============================================================

=head2 process_items_in_queue

=head3 INPUT

=head3 OUTPUT

=head3 DESCRIPTION

=cut

#=============================================================
sub process_items_in_queue {
    my $self = shift;

    $log->info("Start consuming items...");
    $self->queue->consume( \&_index_item, "drop" );
}

#=============================================================

=head2 _index_item

=head3 INPUT

A Mir::Doc::File object or a hash representing a doc profile

=head3 OUTPUT

The result of the index or undef in case of errors.

=head3 DESCRIPTION

Queue items consuming callback.
Tries to extract the text from the object and index it in the 
index, for the type and with the mapping configured.

=cut

#=============================================================
sub _index_item {
    my $item = (ref $_[0] eq 'HASH') ? $_[0] : $_[1];

    $log->info( "Found NEW item -------------------------------------------");
    $log->info( $item->{id} );
    $log->debug( Dumper ( $item ) );

    unless ( $item ) {
        $log->error( "No item found!" );
        return 0; 
    }

    $item->{abspath} = decode_utf8( $item->{abspath} );
    if ( not -f "$item->{abspath}" ) {
        $log->error( "File $item->{abspath} not exists or not readable" );
        return 0; 
    }

    my $orig_id = $item->{id};
    my $item_obj = Mir::Doc::File->unpack( $item );
    $item_obj->id( $orig_id );
    unless ( $item_obj ) {
        $log->error("Error getting back a Mir::Doc::File obj");
        return;
    }
    my $item_to_index = $item_obj->to_index();

    get_text( $item_to_index );

    my $ret;
    try {
        # index item in the proper index...
        $log->info("Indexing document: $item_to_index->{id}");
        $log->debug( Dumper $item_to_index );

        $ret = $e->index( 
            index   => $index,
            type    => $type,
            body    => $item_to_index 
        );
        if ( $ret->{_id} ) {
            $log->info("Indexed document $item_to_index->{id}, IDX id: $ret->{_id}");
            $item_obj->{idx_id}     = $ret->{_id};
            $item_obj->{num_pages}  = $item_to_index->{num_pages};
            $item_obj->{mean_confidence} = $item_to_index->{mean_confidence};
            $item_obj->{status}     = Mir::Doc::INDEXED; 
            $item_obj->store();
            $stat->incrBy();
        } else {
            $log->error("Error indexing document $item_to_index->{id}, no IDX ID");
        }
    } catch ( $err ) {
        $log->error("Error indexing document $item->{id}: $err");
    };
    return ( $ret );
}

#=============================================================

=head2 get_text

=head3 INPUT

    $doc : the document metadata hashref

=head3 OUTPUT

1/undef in case of errors

=head3 DESCRIPTION

Tries its best to get the page texts out of the document.
Computes the overall text extraction confidence.
Page text is collected in the arrayref $doc->{text}.

=cut

#=============================================================
sub get_text {
    my $doc = $_[0];

    $doc->{text} = [];
    $doc->{mean_confidence} = 0;

    my $dh;
    my $mean_confidence=0;
    if ( $doc->{suffix} && ( $dh = Mir::Util::DocHandler->create( driver => get_driver ( $doc->{suffix} ) ) ) ) {
        $log->info("Opening doc $doc->{abspath}...");
        $dh->open_doc( "$doc->{abspath}" ) or return;
    
        $doc->{num_pages} = $dh->pages();
        $log->info( "Doc has $doc->{num_pages} pages" );
    
        foreach( my $page=1;$page<=$doc->{num_pages};$page++ ) {
            # get page text and confidence
            # add them to item profile
            my ( $text, $confidence ) = $dh->page_text( $page, '/tmp' );
            if ( ( $confidence > $confidence_threashold ) && 
                 ( $text ) ) {
                push @{ $doc->{text} }, $text;
                $mean_confidence += $confidence;
            }
        }
        $doc->{mean_confidence} = $mean_confidence/$doc->{num_pages};
    } else {
        $log->warn("WARNING: no Mir::Util::DocHandler driver for document $doc->{abspath}");
        return 0;
    }

    return 1;
}

#=============================================================

=head2 get_driver

=head3 INPUT

=head3 OUTPUT

=head3 DESCRIPTION

Returns the Mir::Util::DocHandler driver based on the document
suffix.

=cut

#=============================================================
sub get_driver {
    my $suffix = shift;
    ( $drivers_lut->{$suffix} ) ? return $drivers_lut->{$suffix} : $suffix;
}

#=============================================================

=head2 exists

=head3 INPUT

    $id: the document id

=head3 OUTPUT

1 if doc exists

=head3 DESCRIPTION

Check if document with the passed id has been already indexed.
Returns the total number of hits found.

=cut

#=============================================================
sub exists {
    my ( $self, $id, $index ) = @_;

    return undef unless $id;
    my $filter = { 
        match => { id => $id }
    };
    my $res;
    try {
        $res = $e->search(
            index => $index,
            body  => { query => $filter }
        );
    } catch {
        $log->error("Error checking for doc $id: $@");
        return undef;
    }
    return $res->{hits}->{total};
}

1;

__DATA__
{
    "pdf":  "pdf3",
    "html": "html",
    "doc":  "doc",
    "docx": "doc",
    "rtf":  "rtf",
    "java": "txt",
    "js":   "txt",
    "pm":   "txt"
}
