package VisLlama::Chat;
# GPL-3.0-only. Narrow chat mount boundary: active connection and observed
# capabilities only. Generation remains on the existing public inference API.
use strict;
use warnings;
use JSON::PP qw(decode_json);
use HTTP::Tiny;
use VisLlama::Context qw($STATE);
use VisLlama::ProcessState ();
use VisLlama::Router ();
use VisLlama::HTTP ();
use VisLlama::Util qw(jtrue jfalse);
# Optional metadata probes must not change engine readiness or trigger loading.
sub engine_metadata {
    my ($eng,$path)=@_;
    return unless $eng && $eng->{port};
    my $ua=HTTP::Tiny->new(timeout=>2,no_proxy=>['127.0.0.1','localhost']);
    my $r=$ua->get('http://127.0.0.1:'.int($eng->{port}).$path);
    return unless $r->{success};
    return eval {decode_json($r->{content})};
}
sub handle {
    my ($sock,$path,$req)=@_;
    my $running=VisLlama::ProcessState::proc_running();
    my $router=($STATE->{mode}//'') eq 'router';
    my @models;my $context;
    if ($running && $router) {
        my %seen;
        for my $id (sort keys %{$STATE->{router_engines}||{}}) {
            my $e=$STATE->{router_engines}{$id};
            next unless VisLlama::ProcessState::router_engine_running($e);
            push @models,map {{id=>$_}} grep {!$seen{$_}++} @{$e->{models}||[]};
        }
        if ($req->{model}) {
            my $eng=VisLlama::Router::router_engine_for_model($req->{model});
            if ($eng) {
                # Never autoload a model through a metadata probe. Calculated
                # placement stays exclusively on the centralized request path.
                my $snapshot=eval {engine_metadata($eng,'/v1/models')};
                my $state;
                if (ref($snapshot) eq 'HASH' && ref($snapshot->{data}) eq 'ARRAY') {
                    for my $row (@{$snapshot->{data}}) {
                        next unless ref($row) eq 'HASH' && ($row->{id}//'') eq $req->{model};
                        $state=ref($row->{status}) eq 'HASH' ? $row->{status}{value} : $row->{status};
                    }
                }
                if (($state//'') eq 'loaded' && $req->{model}=~/^[A-Za-z0-9._:-]+$/) {
                    my $props=eval {engine_metadata($eng,'/props?autoload=false&model='.$req->{model})};
                    $context=$props->{default_generation_settings}{n_ctx} if ref($props) eq 'HASH' && ref($props->{default_generation_settings}) eq 'HASH';
                }
            }
        }
    } elsif ($running) {
        my $host=$STATE->{direct_host}||'127.0.0.1';$host='127.0.0.1' if $host eq '0.0.0.0';$host='::1' if $host eq '::';
        my $url_host=$host=~/:/ && $host!~/^\[/ ? "[$host]" : $host;
        my $port=$STATE->{direct_port}||8080;
        my $ua=HTTP::Tiny->new(timeout=>2,no_proxy=>[$host,'127.0.0.1','localhost']);
        my $response=$ua->get("http://$url_host:$port/v1/models");my $data=eval {decode_json($response->{content})};
        @models=map {{id=>$_->{id}}} grep {ref($_) eq 'HASH' && defined($_->{id}) && !ref($_->{id})} @{$data->{data}||[]} if ref($data) eq 'HASH' && ref($data->{data}) eq 'ARRAY';
        if ($req->{model} && grep {$_->{id} eq $req->{model}} @models) {
            my $p=$ua->get("http://$url_host:$port/props");my $props=eval {decode_json($p->{content})};
            $context=$props->{default_generation_settings}{n_ctx} if ref($props) eq 'HASH' && ref($props->{default_generation_settings}) eq 'HASH';
        }
    }
    $context=undef unless defined($context) && !ref($context) && $context=~/^\d+$/ && $context>0;
    my $available=$running && (!$router || VisLlama::ProcessState::proxy_running());
    return VisLlama::HTTP::json_response($sock,200,{ok=>jtrue,available=>$available?jtrue:jfalse,
        mode=>$router?'router':'single',host=>$router?$STATE->{router_host}:$STATE->{direct_host},
        port=>$router?$STATE->{router_port}:$STATE->{direct_port},models=>\@models,context_size=>$context,
        capabilities=>{streaming=>jtrue,cancellation=>jtrue,usage=>'optional',reasoning=>'optional',timings=>'optional'}});
}
1;
