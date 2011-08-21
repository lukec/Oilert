package Oilert::Base;
use Moose::Role;
use Oilert::Redis;
use YAML qw/LoadFile/;
use FindBin;
use Try::Tiny;
use feature 'state';
use methods;

has 'config' => (is => 'ro', isa => 'HashRef', lazy_build => 1);
has 'redis'  => (is => 'ro', isa => 'Oilert::Redis', lazy_build => 1);

method _build_config {
    state $config;
    my $file = "/home/dotcloud/services.yaml";
    $file = "$FindBin::Bin/etc/services.yaml" unless -e $file;
    $file = "$FindBin::Bin/../etc/services.yaml" unless -e $file;
    return try { $config ||= LoadFile($file) }
    catch { die "Yaml could not open $file: $_" };
}

method _build_redis { Oilert::Redis->new }
