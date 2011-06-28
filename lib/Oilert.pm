package Oilert;
use Dancer ':syntax';
use YAML qw/LoadFile/;

our $VERSION = '0.1';

get '/' => sub {
    my $data = LoadFile("data/ships.yaml");

    template 'index', {
        ships => [ @{ $data->{Tanker} }, @{ $data->{Cargo} } ],
    };
};

true;
