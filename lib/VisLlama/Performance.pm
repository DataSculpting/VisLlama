package VisLlama::Performance;
# GPL-3.0-only. Bounded in-memory timings; labels never contain command arguments.
use strict;
use warnings;
my %TIMINGS;
sub record {
    my ($name,$seconds)=@_;return if !exists($TIMINGS{$name}) && keys(%TIMINGS)>=64;
    my $r=$TIMINGS{$name} ||= {count=>0,total_ms=>0,max_ms=>0,last_ms=>0};
    my $ms=int($seconds*1000);$r->{count}++;$r->{total_ms}+=$ms;
    $r->{last_ms}=$ms;$r->{max_ms}=$ms if $ms>$r->{max_ms};
}
sub payload {return {map {$_=>{%{$TIMINGS{$_}}}} keys %TIMINGS}}
1;
