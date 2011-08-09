#!/usr/bin/env perl
use 5.12.0;
use Test::More;
use lib 'lib';

use_ok 'Oilert::Notifier';
use_ok 'Oilert::ShipDatabase';

my $N = Oilert::Notifier->new;
$N->clear_state();
ok $N, 'notifier exists';

# Create a bunch of ships for testing.
my $base_ship = Oilert::Ship->new(
    mmsi => 1234,
    name => 'Test',
    type => 'Tanker',
);

subtest Ship_outside_BI => sub {
    my $ship = $base_ship->clone_with(
        lat => 49.3, # within the north/south of BI
        lon => -124.0, # west of BI
    );
    my $res = $N->_check(undef, $ship);
    ok !$res, 'no notification necessary';
};

subtest ship_comes_in_and_goes => sub {
    my $ship = $base_ship->clone_with(
        lat => 49.310909,
        lon => -122.984734,
    );
    my $res = $N->_check(undef, $ship);
    is $res->{reason}, 'entered the Burrard Inlet', 'correct reason';
    $res = $N->_check(undef, $ship);
    ok !$res, 'no notification a second time';


    my $ship_near_wrmt = $ship->clone_with(
        lat => 49.292023,
        lon => -122.959068,
    );
    $res = $N->_check($ship, $ship_near_wrmt);
    is $res->{reason}, 'docked at Westridge', 'correct reason';
    $res = $N->_check($ship, $ship_near_wrmt);
    ok !$res, 'no notification a second time';
    
    $res = $N->_check($ship_near_wrmt, $ship);
    like $res->{reason}, qr/filled up with oil, probably will leave at \d+:\d+/, 'correct reason';
    $res = $N->_check($ship_near_wrmt, $ship);
    ok !$res, 'no notification a second time';

    my $outside = $ship->clone_with(
        lat => 49.3, # within the north/south of BI
        lon => -124.0, # west of BI
    );
    $res = $N->_check($ship, $outside);
    is $res->{reason}, 'left the Burrard Inlet full of oil', 'correct reason';
};

done_testing();
