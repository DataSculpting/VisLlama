#!/usr/bin/env perl
# Synthetic HTTP engine for Linux lifecycle tests, never model inference.
use strict;use warnings;use IO::Socket::INET;use JSON::PP qw(encode_json decode_json);
if(grep {$_ eq '--help'} @ARGV){print "  --models-preset FILE  Presets\n";exit 0;}
if(grep {$_ eq '--version'} @ARGV){print "version: b12345\n";exit 0;}
if(grep {$_ eq '--list-devices'} @ARGV){exit 0;}
my %args;for(my $i=0;$i<@ARGV-1;$i++){$args{$ARGV[$i]}=$ARGV[$i+1];}
my %models;
if($args{'--models-preset'}){
 open my $fh,'<:raw',$args{'--models-preset'} or die $!;
 while(<$fh>){$models{$1}='unloaded' if /^\[([^*][^\]]*)\]/;}close $fh;
}else{$models{'direct'}='loaded';}
my $server=IO::Socket::INET->new(LocalAddr=>'127.0.0.1',LocalPort=>$args{'--port'},Proto=>'tcp',Listen=>20,ReuseAddr=>1) or die $!;
$|=1;print "Fixture ready\n";
while(my $sock=$server->accept()){
 $sock->autoflush(1);my $line=<$sock>//'';my ($method,$path)=$line=~/^(\S+) (\S+)/;my $len=0;
 while(my $h=<$sock>){last if $h =~ /^\r?\n$/;$len=$1 if $h =~ /^Content-Length:\s*(\d+)/i;}
 my $body='';read($sock,$body,$len) if $len;my $request=length($body)?decode_json($body):{};
 if($path eq '/models/load'){$models{$request->{model}}='loaded';if($ENV{VISLLAMA_TEST_EVENT_LOG}){open my $f,'>>:raw',$ENV{VISLLAMA_TEST_EVENT_LOG} or die $!;print {$f} $request->{model}."\n";close $f;}}
 if($path eq '/models/unload'){$models{$request->{model}}='unloaded';}
 my $data=$path =~ m{^/v1/models}?{data=>[map {{id=>$_,object=>'model',status=>{value=>$models{$_}}}} sort keys %models]}:{ok=>JSON::PP::true};
 my $json=encode_json($data);print {$sock} "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ".length($json)."\r\nConnection: close\r\n\r\n$json";close $sock;
}
