#!/usr/bin/env perl
use 5.12.0;
use Test::More;
use lib 'lib';

use_ok 'Oilert::Notifier';

my $notifier = Oilert::Notifier->new;
$notifier->clear_state();
ok $notifier, 'notifier exists';

my %data;

No_ships: {
    my $res = $notifier->check(\%data);
    is scalar(@$res), 0;
}

New_ship: {
    $data{Tanker} = [
        {
            mmsi => 12345,
            name => "test ship",
            detail_url => 'http://test',
            speed => 10,
        }
    ];
    my $res = $notifier->check(\%data);
    is scalar(@$res), 1;
    is $res->[0]->{ship}{name}, 'test ship';
    is $res->[0]->{reason}, "entered the Burrard Inlet";

    my $res = $notifier->check(\%data);
    is scalar(@$res), 0, 'no duplicate notifications';
}

Ship_stops_moving: {
    $data{Tanker}[0]{speed} = 0.1;
    my $res = $notifier->check(\%data);
    is scalar(@$res), 1;
    is $res->[0]->{ship}{name}, 'test ship';
    is $res->[0]->{reason}, "stopped moving";

    my $res = $notifier->check(\%data);
    is scalar(@$res), 0, 'no duplicate notifications';
}

Ship_starts_moving: {
    $data{Tanker}[0]{speed} = 7;
    my $res = $notifier->check(\%data);
    is scalar(@$res), 1;
    is $res->[0]->{ship}{name}, 'test ship';
    is $res->[0]->{reason}, "started moving";

    my $res = $notifier->check(\%data);
    is scalar(@$res), 0, 'no duplicate notifications';
}

Ship_leaves: {
    $data{Tanker} = [];
    my $res = $notifier->check(\%data);
    is scalar(@$res), 1;
    is $res->[0]->{ship}{name}, 'test ship';
    is $res->[0]->{reason}, "left the Burrard Inlet";

    my $res = $notifier->check(\%data);
    is scalar(@$res), 0, 'no duplicate notifications';
}

done_testing();
