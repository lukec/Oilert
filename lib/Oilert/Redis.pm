package Oilert::Redis;
use 5.12.0;
use Dancer ':syntax';
use methods;
use Moose;
use Redis;
use JSON qw/encode_json decode_json/;
use Try::Tiny;

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
    my $json = $self->redis->get($key);
    return decode_json($json);
}
    

method _build_redis {
    my $env_file = "/home/dotcloud/environment.json";
    if (-e $env_file) {
        my $env = load_env($env_file);
        my $server = $env->{DOTCLOUD_MYREDIS_REDIS_URL};
        $server =~ s#^redis://redis:(.+?)\@##;
        my $pass = $1;

        my $r = Redis->new(server => $server);
        $r->auth($pass);
        return $r;
    }
    else {
        return Redis->new
    }
}

sub load_env {
    my $file = shift;
    open(my $fh, $file);
    local $/ = undef;
    my $json = <$fh>;
    close $fh;

    return decode_json($json);
}
