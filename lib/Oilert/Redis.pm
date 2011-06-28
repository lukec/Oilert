package Oilert::Redis;
use 5.14.0;
use methods;
use Moose;
use Redis;

has 'redis' => (is => 'ro', isa => 'Redis', lazy_build => 1, handles => [qw/get set/]);

method _build_redis { Redis->new }
