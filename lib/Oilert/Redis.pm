package Oilert::Redis;
use 5.12.0;
use methods;
use Moose;
use Redis;
use JSON qw/encode_json decode_json/;

has 'redis' => (is => 'ro', isa => 'Redis', lazy_build => 1, 
                handles => [qw/get set del sismember rpush type sadd srem smembers keys/]);

method set_json {
    my $key = shift;
    my $val = shift;

    $val = encode_json($val);
    $self->redis->set($key, $val);
};

method get_json {
    my $key = shift;
    my $val = $self->redis->get($key);
    return decode_json($val);
}
    

method _build_redis {
    my $env_file = "/home/dotcloud/environment.json";
    if (-e $env_file) {
        my $env = load_env($env_file);
        my $server = $env->{DOTCLOUD_MYREDIS_REDIS_URL};
        $server =~ s#^redis://##;
        my $r = Redis->new(server => $server);
        $r->auth($env->{REDIS_PASSWORD});
        return $r;
    }
    else {
        return Redis->new
    }
}

sub load_json {
    my $file = shift;
    open(my $fh, $env_file);
    local $/ = undef;
    my $json = <$fh>;
    close $fh;

    my $env = decode_json($json);

    # Hack to work around dotcloud bug:
    open($fh, "/home/dotcloud/redis-environment.json");
    $json = <$fh>;
    my $redis_env = decode_json($json);
    $env->{REDIS_PASSWORD} = $redis_env->{password};
    return $env;
}
