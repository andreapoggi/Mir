package Mir::Config::Client::JSON;
#============================================================= -*-perl-*-

=head1 NAME

Mir::Config::Client::JSON - implements the Mir::R::Config role 
on a JSON encoded configuration file.

=head1 VERSION

0.01

=cut

use vars qw( $VERSION );
$VERSION='0.01';

=head1 SYNOPSIS

    use Mir::Config::Client;
    my $o = Mir::Config::Client->create( 
        driver => 'JSON',
        params => {
            path => '...'
        });

    # opens and parses the file...
    $o->connect() 
        or die "Error getting a Mir::Config::Client::JSON obj\n";

    # refer to L<Mir::R::Config> role for detailed API documentation

=head1 DESCRIPTION

A class that handles Mir::Config sections on a Mongo data store.

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
use JSON;
use Log::Log4perl;
use TryCatch;
with 'Mir::R::Config';

has 'path' => ( is => 'rw', isa => 'Str' );

has 'config' => ( is => 'rw', isa => 'ArrayRef' );

has 'log' => (
    is => 'ro',
    isa => 'Log::Log4perl::Logger',
    default => sub {
        return Log::Log4perl->get_logger( __PACKAGE__ );
    }
);

#=============================================================

=head2 connect

=head3 INPUT

=head3 OUTPUT

1 in case of success otherwise undef

=head3 DESCRIPTION

Tries to open the file and parse the content...

=cut

#=============================================================
sub connect {
    my  $self = shift;

    try {
        die "No path configured!\n"     unless ( $self->path );
        die "No config file found!\n"   unless ( -f $self->path );
        my $json;
        {
            local $/;
            my $fh;
            open $fh, "<$self->{path}";
            $json = <$fh>;
            close $fh;
        }
        $self->config( decode_json ( $json ) );
    } catch ( $err ) {
        $self->log->error($err);
        return undef;
    };

    return $self;
}

#=============================================================

=head2 get_section

=head3 INPUT

=head3 OUTPUT

=head3 DESCRIPTION

=cut

#=============================================================
sub get_section {
    my ( $self, $section ) = @_;

#    if ( $section ) {
#        $self->_set_collection( $self->database->get_collection( $section ) )
#            or die "Error getting section $section\n";
#    }
    #
#    return undef unless $self->collection;
#    my $cursor = $self->collection->find();
#    
#    return [ $cursor->all ];
}

#=============================================================

=head2 get_id

=head3 INPUT

=head3 OUTPUT

=head3 DESCRIPTION

=cut

#=============================================================
sub get_id {
    my ( $self, $id ) = @_;
    
#    return undef unless $self->collection;
#    my $obj = $self->collection->find_one({ _id => $id });
    #
#    return $obj;
}

#=============================================================

=head2 get_key

=head3 INPUT

    $keys:  An hashref with a list of key/value pairs
    $attrs: An hashref with the list of attributes to have back( {a=>1,b=>1,...} )

=head3 OUTPUT

An arrayref.

=head3 DESCRIPTION

Looks in the config data for all structures matching the list of keys passed.
Returns only the selected attributes.
Note: currently $keys and $attrs must be first level keys.

=cut

#=============================================================
sub get_key {
    my ( $self, $keys, $attrs ) = @_;

    my $out_params = [];
    foreach my $section ( @{ $self->config } ) {
        my $found = 0;
        foreach my $key ( keys %$keys ) {
            if (( exists $section->{ $key } )&& 
                ( $keys->{$key} eq $section->{ $key } ) )  {
                $found++;
            }
        }
        if ( $found == scalar keys ( %$keys ) ) {
            my $doc = {};
            foreach my $attr ( keys %$attrs ) {
                $doc->{ $attr } = $section->{ $attr }  
                    if ( exists $section->{ $attr } );
            }
            push @$out_params, $doc;
        }
    }

    return $out_params;
}

1; # End of Mir::Config::Client::Mongo
