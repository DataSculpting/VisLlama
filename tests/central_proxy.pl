use strict;
use warnings;
use IO::Socket::INET;
use JSON::PP qw(encode_json decode_json);
use File::Temp qw(tempdir);
use File::Spec;
use File::Basename qw(dirname);
use IPC::Open3;
use Symbol qw(gensym);
use Time::HiRes qw(sleep);
use threads;
use threads::shared;

my @events :shared;

sub listener {
    my $server = IO::Socket::INET->new(LocalAddr=>'127.0.0.1',LocalPort=>0,Proto=>'tcp',Listen=>8,ReuseAddr=>1)
        or die "Unable to open local test listener: $!";
    return $server;
}

sub serve_mock {
    my ($server,$role,$requests) = @_;
    for (1..$requests) {
        my $client = $server->accept() or die "Test $role accept failed: $!";
        $client->autoflush(1);
        my $line = <$client>;
        my $length = 0;
        while (my $header = <$client>) {
            last if $header =~ /^\r?\n$/;
            $length = $1 if $header =~ /^Content-Length:\s*(\d+)/i;
        }
        my $body = '';
        while (length($body) < $length) {
            my $read = read($client,my $part,$length-length($body));
            die "Test $role request truncated" unless $read;
            $body .= $part;
        }
        my $model = decode_json($body)->{model};
        { lock(@events); push @events,"$role:$model"; }
        my $reply = encode_json({ok=>JSON::PP::true,model=>$model});
        print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " . length($reply)
            . "\r\nConnection: close\r\n\r\n$reply";
        close $client;
    }
    close $server;
}

sub request_proxy {
    my ($port,$model) = @_;
    my $client = IO::Socket::INET->new(PeerAddr=>'127.0.0.1',PeerPort=>$port,Proto=>'tcp',Timeout=>5)
        or die "Proxy request failed: $!";
    my $body = encode_json({model=>$model});
    print $client "POST /v1/chat/completions HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: "
        . length($body) . "\r\nConnection: close\r\n\r\n$body";
    my $status = <$client> // '';
    die "Unexpected proxy response for $model: $status" unless $status =~ m{^HTTP/1\.1 200\b};
    close $client;
}

my $control = listener();
my $backend = listener();
my $control_port = $control->sockport;
my $backend_port = $backend->sockport;
my $probe = listener();
my $proxy_port = $probe->sockport;
close $probe;

my $dir = tempdir(CLEANUP=>1);
my $route_file = File::Spec->catfile($dir,'routes.json');
open my $route,'>',$route_file or die $!;
print $route encode_json({
    models=>{
        calculated=>{host=>'127.0.0.1',port=>$backend_port,calculated=>1},
        ordinary=>{host=>'127.0.0.1',port=>$backend_port,calculated=>0},
    },
    backends=>[{host=>'127.0.0.1',port=>$backend_port}],
    control=>{port=>$control_port,token=>'test-secret'},
});
close $route;

my $control_thread = threads->create(\&serve_mock,$control,'control',1);
my $backend_thread = threads->create(\&serve_mock,$backend,'backend',2);
my $proxy_file = File::Spec->catfile(dirname(dirname(__FILE__)),'llama_openai_proxy.pl');
my ($proxy_out,$proxy_err) = (gensym(),gensym());
my $pid = open3(undef,$proxy_out,$proxy_err,$^X,$proxy_file,
    '--listen-host','127.0.0.1','--listen-port',$proxy_port,'--route-map',$route_file);
my $ok = eval {
    my $ready;
    for (1..50) {
        $ready = IO::Socket::INET->new(PeerAddr=>'127.0.0.1',PeerPort=>$proxy_port,Proto=>'tcp',Timeout=>1);
        last if $ready;
        sleep(0.05);
    }
    die 'Proxy did not start' unless $ready;
    close $ready;
    request_proxy($proxy_port,'calculated');
    request_proxy($proxy_port,'ordinary');
    1;
};
my $error = $@;
kill 'TERM',$pid;
waitpid($pid,0);
die $error unless $ok;
$control_thread->join();
$backend_thread->join();
die 'Calculated requests must load centrally before reaching the engine; ordinary models bypass the loader'
    unless join('|',@events) eq 'control:calculated|backend:calculated|backend:ordinary';
print "Calculated proxy handoff passed\n";
