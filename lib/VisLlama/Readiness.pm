package VisLlama::Readiness;
# GPL-3.0-only. Launcher liveness and observed HTTP/model readiness are distinct.
use strict;
use warnings;
use Time::HiRes qw(time);
use VisLlama::Context qw($STATE);
use VisLlama::Util qw(jtrue jfalse);
sub refresh_endpoint {
    return if $STATE->{active_operation};
    my $router=($STATE->{mode}//'') eq 'router';
    my $port=$router?$STATE->{router_port}:$STATE->{direct_port};
    return unless $port && ($router?$STATE->{proxy_proc}:$STATE->{proc});
    return if time()-($STATE->{endpoint_checked_at}||0)<5;
    require HTTP::Tiny;
    my $host=$router?($STATE->{router_host}||'127.0.0.1'):($STATE->{direct_host}||'127.0.0.1');
    $host='127.0.0.1' if $host eq '0.0.0.0';$host='::1' if $host eq '::';
    $host='['.$host.']' if $host =~ /:/ && $host !~ /^\[/;
    my $r=HTTP::Tiny->new(timeout=>0.75,no_proxy=>[$host,'127.0.0.1','localhost'])->get("http://$host:$port/health");
    $STATE->{endpoint_checked_at}=time();$STATE->{endpoint_ready}=$r->{success}?1:0;
}
sub snapshot {
    my ($running)=@_;
    my @engines;
    my %engines=(%{$STATE->{router_engines}||{}},%{$STATE->{starting_engines}||{}});
    for my $key (sort keys %engines) {
        my $eng=$engines{$key};
        my $fresh=time()-($eng->{ready_checked_at}||0)<15;
        push @engines,{group=>$key,build=>$eng->{build},state=>$eng->{engine} && !$eng->{proc}?'idle':!$eng->{proc}?'stopped':!$fresh?'unknown':$eng->{ready}?'ready':'unavailable',checked_at=>$eng->{ready_checked_at}};
    }
    my $fresh=time()-($STATE->{endpoint_checked_at}||0)<15;
    my $endpoint=!$running?'stopped':!$fresh?'unknown':$STATE->{endpoint_ready}?'ready':'unavailable';
    my @startup=@{$STATE->{startup_models}||[]};
    my $failed=grep {($_->{state}//'') eq 'failed'} @startup;
    my $phase=!$running?'stopped':$STATE->{active_operation} && ($STATE->{active_operation}{path}//'') eq '/api/start'?'starting':
        $failed?'partial':$STATE->{catalog_apply_incomplete}?'degraded':$endpoint eq 'unavailable'||grep({$_->{state} eq 'unavailable'||$_->{state} eq 'stopped'} @engines)?'degraded':
        $endpoint eq 'ready'&&!grep({$_->{state} ne 'ready' && $_->{state} ne 'idle'} @engines)?'ready':'checking';
    return {phase=>$phase,endpoint=>$endpoint,endpoint_checked_at=>$STATE->{endpoint_checked_at},engines=>\@engines,startup_models=>\@startup,
        catalog_apply_incomplete=>$STATE->{catalog_apply_incomplete}?jtrue:jfalse,
        startup_failed=>0+$failed,ready=>$phase eq 'ready'?jtrue:jfalse};
}
1;
