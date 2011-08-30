package Oilert::ShipDatabase;
use 5.12.0;
use Dancer ':syntax';
use Moose;
use methods;
use Oilert::Redis;
use Oilert::Notifier;
use LWP::UserAgent;

has 'db' => (is => 'rw', isa => 'Oilert::Redis', lazy_build => 1);
has 'notifier' => (is => 'ro', isa => 'Oilert::Notifier', lazy_build => 1);

method ignore { $self->db->sadd('mmsi_ignore', shift) }
method should_ignore { $self->db->sismember('mmsi_ignore', shift) }

method get_ship {
    my $mmsi = shift;
    my $ship = $self->db->get_json($mmsi);
    return Oilert::Ship->new($ship) if $ship;
    $ship = Oilert::Ship->new(mmsi => $mmsi);
    $ship->scrape;
    return $ship;
}

method save {
    my $ship = shift;
    my $mmsi = $ship->mmsi;
    eval {
        my $old_ship = $self->db->get_json($mmsi);
        $self->notifier->update($old_ship, $ship) if $ship->is_a_tanker;
        $ship->last_update(time);
        $self->db->set_json($mmsi, $ship->to_hash);
        my $now = DateTime->now;
        $now->set_time_zone('America/Vancouver');
        $self->db->set(last_update => $now->ymd . ' ' . $now->hms);
        print " (Saved " . $ship->name . " ($mmsi)) ";
    };
    warn $@ if $@;
}

method ships {
    my @ships;
    for my $mmsi ($self->db->smembers('ships_in_bi')) {
        my $obj = $self->db->get_json($mmsi);
        unless ($obj) {
            $self->db->srem('ships_in_bi', $mmsi);
            next;
        }
        push @ships, Oilert::Ship->new($obj);
    }
    return \@ships;
}

method last_update { $self->db->get('last_update') || 'Never' }

method _build_db { Oilert::Redis->new }
method _build_notifier { Oilert::Notifier->new }

package Oilert::Ship;
use Dancer qw/:syntax/;
use Moose;
use methods;
use Math::Polygon;
use DateTime;

has 'mmsi' => (is => 'rw', isa => 'Str', required => 1);
has 'lat' => (is => 'rw', isa => 'Num');
has 'lon' => (is => 'rw', isa => 'Num');
has 'name' => (is => 'rw', isa => 'Str');
has 'type' => (is => 'rw', isa => 'Str');
has 'speed' => (is => 'rw', isa => 'Num', default => 0);
has 'has_filled_up' => (is => 'rw', isa => 'Bool', default => 0);
has 'last_update' => (is => 'rw', isa => 'Num', default => sub { time });
has 'length' => (is => 'rw', isa => 'Maybe[Num]');

method to_hash {
    return {
        map { $_ => $self->$_ } 
        qw/mmsi lat lon name has_filled_up type speed last_update length/
    }
}

has 'polygon_east_of_second_narrows'  => (is => 'ro', lazy_build => 1);
has 'polygon_near_westridge_terminal' => (is => 'ro', lazy_build => 1);
has 'polygon_for_webcam'              => (is => 'ro', lazy_build => 1);

method detail_url {
    "http://marinetraffic.com/ais/shipdetails.aspx?mmsi=".$self->mmsi;
}

method as_string {
    my $dt = DateTime->from_epoch(epoch => $self->last_update);
    return $self->name . ' (' . $self->mmsi . ') last-update=' . $dt;
}

method location_str { "Lat/Lon: " . $self->lat . '/' . $self->lon }

method is_a_tanker {
    $self->scrape unless $self->type;
    return $self->type =~ m/^tanker/i;
}

method is_textable {
    $self->scrape unless $self->type and $self->length;
    return $self->is_a_tanker && $self->length > 200;
}

method is_in_binlet {
    $self->polygon_east_of_second_narrows->contains(
        [ $self->lat, $self->lon ]);
}

method is_near_wrmt {
    $self->polygon_near_westridge_terminal->contains(
        [ $self->lat, $self->lon ]);
}

method is_in_webcam_range {
    $self->polygon_for_webcam->contains([ $self->lat, $self->lon ]);
}

method scrape {
    print "FETCH:" . $self->mmsi;
    my $ua = LWP::UserAgent->new(agent =>
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_6_8) AppleWebKit/534.30 "
        . "(KHTML, like Gecko) Chrome/12.0.742.112 Safari/534.30");
    my $uri = $self->detail_url;
    my $resp = $ua->get($uri);
    if ($resp->code == 200) {
        my $content = $resp->content;
        $content =~ m(<b>Ship Type:</b>\s*(\w+)<br/>);
        $self->type($1 || 'Unknown');
        $content =~ m/title='([^']+)'/;
        $self->name($1 || 'No-Name');
        $content =~ m(<b>Length x Breadth:</b>\s*(\d+)\s+m\s+X);
        $self->length($1 || 0);
        print " (Scraped "
            . $self->type . " "
            . $self->name . " - "
            . $self->length . "m) ";
    }
    else {
        warn "Failed to scrape " . $self->detail_url;
    }
}

# For testing
method clone_with {
    my $newship = { %$self, @_ };
    bless $newship, ref($self);
    return $newship;
}

method _build_polygon_east_of_second_narrows {
    Math::Polygon->new(
        [49.3021,-123.0029],
        [49.3109,-122.9847],
        [49.3182,-122.9383],
        [49.2944,-122.8353],
        [49.2791,-122.8575],
        [49.2903,-122.9970],
        [49.3021,-123.0029],
    );
}

method _build_polygon_near_westridge_terminal {
    Math::Polygon->new(
        [49.2921,-122.9677],
        [49.2928,-122.9469],
        [49.2896,-122.9469],
        [49.2875,-122.9677],
        [49.2921,-122.9677],
    );
}

method _build_polygon_for_webcam {
    Math::Polygon->new(
        [49.3107,-123.0939],
        [49.3053,-123.0803],
        [49.2847,-123.1096],
        [49.3107,-123.0939],
    );
}

