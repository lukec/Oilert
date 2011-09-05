#!/usr/bin/env perl
use 5.10.0;
use Test::More;
use lib 'lib';

use_ok 'Oilert::Notifier';
use_ok 'Oilert::ShipDatabase';

my $N = Oilert::Notifier->new;
ok $N, 'notifier exists';
my $test_mmsi = 1234;
$N->redis->del($test_mmsi);
$N->redis->srem('mmsi_ignore', $test_mmsi);
$N->redis->srem('ships_in_bi', $test_mmsi);
$N->redis->srem('ships_at_WRMT', $test_mmsi);

# Create a bunch of ships for testing.
my $base_ship = Oilert::Ship->new(
    mmsi => $test_mmsi,
    name => 'Test',
    type => 'Tanker',
);

subtest Ship_outside_BI => sub {
    my $ship = $base_ship->clone_with(
        lat => 49.3, # within the north/south of BI
        lon => -124.0, # west of BI
    );
    my $res = $N->_check(undef, $ship);
    no_notify_ok($res, 'no notification necessary');
};

subtest ship_comes_in_and_goes => sub {
    my $ship = $base_ship->clone_with(
        lat => 49.310,
        lon => -122.984,
    );
    my $res = $N->_check(undef, $ship);
    is $res->{reason}, 'entered the Burrard Inlet', 'correct reason';
    $res = $N->_check(undef, $ship);
    no_notify_ok($res, 'no notification a second time');


    my $ship_near_wrmt = $ship->clone_with(
        lat => 49.292,
        lon => -122.959,
    );
    $res = $N->_check($ship, $ship_near_wrmt);
    is $res->{reason}, 'docked at Westridge', 'correct reason';
    $res = $N->_check($ship, $ship_near_wrmt);
    no_notify_ok($res, 'no notification a second time');

    # Do again with slightly different coords
    $ship_near_wrmt = $ship->clone_with(
        lat => 49.291,
        lon => -122.949
    );
    $res = $N->_check($ship, $ship_near_wrmt);
    no_notify_ok($res, 'no notification a third time');
    
    $res = $N->_check($ship_near_wrmt, $ship);
    like $res->{reason}, qr/filled up with oil, probably will leave at \d+:\d+/, 'correct reason';
    $res = $N->_check($ship_near_wrmt, $ship);
    no_notify_ok($res, 'no notification a second time');

    my $outside = $ship->clone_with(
        lat => 49.3, # within the north/south of BI
        lon => -124.0, # west of BI
    );
    $res = $N->_check($ship, $outside);
    is $res->{reason}, 'left the Burrard Inlet full of oil', 'correct reason';
};

done_testing();
exit;

sub no_notify_ok {
    my $res = shift;
    my $desc = shift;
    ok !$res, "No notification $desc";
    if ($res) {
        die $res->{reason};
    }
}
