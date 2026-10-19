package VisLlama::Lifecycle;
# GPL-3.0-only. Runtime identity is distinct from OS PIDs and saved presets.
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use Time::HiRes qw(time);
use VisLlama::Context qw($STATE);
our $PUMP;
sub checkpoint {
    my ($expected)=@_;
    $PUMP->() if $PUMP;
    die "Operation cancelled because the runtime changed" if defined($expected) && $expected ne token();
}
sub rotate {
    delete @{$STATE}{qw(endpoint_checked_at endpoint_ready)};
    $STATE->{runtime_token}=sha256_hex(join(':',time(),rand(),$$,{}));
    return $STATE->{runtime_token};
}
sub token {return $STATE->{runtime_token} ||= rotate()}
sub check {
    my ($req)=@_;
    die 'Runtime changed. Refresh status and retry the action.'
        unless defined($req->{runtime_token}) && $req->{runtime_token} eq token();
}
1;
