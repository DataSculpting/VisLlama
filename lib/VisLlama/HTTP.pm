package VisLlama::HTTP;

# Minimal HTTP transport for the administration listener. Responses consume
# bytes; callers render/encode HTML before handing it to this layer.
use VisLlama::Lifecycle ();
use IO::Select;
use Time::HiRes qw(time);
use strict;
use warnings;

use JSON::PP qw(encode_json);

use VisLlama::Util qw(jfalse);
use VisLlama::Errors ();

# -----------------------------------------------------------------------------
# Send a JSON HTTP response from the embedded control server.
# -----------------------------------------------------------------------------
our $STARTED;
sub json_response {
    my ($sock, $code, $obj) = @_;
    $obj={%$obj,runtime_token=>VisLlama::Lifecycle::token(),server_elapsed_ms=>defined($STARTED)?int((time()-$STARTED)*1000):0} if ref($obj) eq 'HASH';
    my $body = encode_json($obj);
    my %reason = (200=>'OK', 400=>'Bad Request', 409=>'Conflict', 404=>'Not Found', 405=>'Method Not Allowed', 500=>'Internal Server Error');
    my $reason = $reason{$code} || 'OK';
    print $sock "HTTP/1.1 $code $reason\r\n";
    print $sock "Content-Type: application/json; charset=utf-8\r\n";
    print $sock "Content-Length: " . length($body) . "\r\n";
    print $sock "Cache-Control: no-store\r\n";
    print $sock "Connection: close\r\n\r\n";
    print $sock $body;
}

# -----------------------------------------------------------------------------
# Send the main HTML application page.
# -----------------------------------------------------------------------------
sub html_response {
    my ($sock, $html) = @_;
    print $sock "HTTP/1.1 200 OK\r\n";
    print $sock "Content-Type: text/html; charset=utf-8\r\n";
    print $sock "Content-Length: " . length($html) . "\r\n";
    print $sock "Cache-Control: no-store\r\n";
    print $sock "Connection: close\r\n\r\n";
    print $sock $html;
}

# -----------------------------------------------------------------------------
# Serve static binary/text assets such as logo and favicon files.
# -----------------------------------------------------------------------------
sub file_response {
    my ($sock, $path, $content_type) = @_;
    open my $fh, '<:raw', $path or return fail_json($sock, 'Asset not found', 404);
    local $/;
    my $data = <$fh>;
    close $fh;
    print $sock "HTTP/1.1 200 OK\r\n";
    print $sock "Content-Type: $content_type\r\n";
    print $sock "Content-Length: " . length($data) . "\r\n";
    # Recheck code/styles after upgrades; images may retain their short cache.
    my $cache = $content_type =~ /(?:javascript|text\/css)/i ? 'no-cache' : 'public, max-age=3600';
    print $sock "Cache-Control: $cache\r\n";
    print $sock "Connection: close\r\n\r\n";
    print $sock $data;
}

# -----------------------------------------------------------------------------
# Return a standard JSON error response.
# -----------------------------------------------------------------------------
sub fail_json {
    my ($sock, $msg, $code) = @_;
    my $error = VisLlama::Errors::public_error($msg);
    json_response($sock, $code || 400, { ok=>jfalse, error=>$error->{message},
        error_code=>$error->{code}, error_ref=>$error->{reference} });
}

# -----------------------------------------------------------------------------
# Read one minimal HTTP request from the embedded control listener.
# -----------------------------------------------------------------------------
sub read_request {
    my ($sock) = @_;
    if (eval {$sock->isa('IO::Socket::INET')}) {
        my $buffer='';my $selector=IO::Select->new($sock);my $deadline=time()+5;
        while ($buffer !~ /\r?\n\r?\n/) {
            die 'HTTP request timed out' unless time()<$deadline && $selector->can_read($deadline-time());
            my $n=sysread($sock,my $chunk,4096);die 'Incomplete HTTP headers' unless $n;
            $buffer.=$chunk;die 'HTTP headers are too large' if length($buffer)>65536;
        }
        my ($head,$body)=split(/\r?\n\r?\n/,$buffer,2);
        my ($length)=$head =~ /^Content-Length:\s*([0-9]+)\s*$/im;
        $length//=0;die 'HTTP request body is too large' if $length>8*1024*1024;
        while(length($body)<$length) {
            die 'HTTP request timed out' unless time()<$deadline && $selector->can_read($deadline-time());
            my $n=sysread($sock,my $chunk,$length-length($body));die 'Incomplete HTTP request body' unless $n;$body.=$chunk;
        }
        my $wire=$head."\r\n\r\n".$body;
        open my $input,'<',\$wire or die 'Cannot parse HTTP request';
        return read_request($input);
    }
    my $request = <$sock>;
    return unless defined $request;
    $request =~ s/\r?\n$//;
    my ($method, $path) = split /\s+/, $request;
    $path =~ s/\?.*\z// if defined $path;
    die 'Invalid HTTP request' unless defined($path) && defined($method);
    my %h; my $complete=0;
    while (my $line = <$sock>) {
        if ($line =~ /^\r?\n$/) {$complete=1;last;}
        $line =~ s/\r?\n$//;
        my ($k,$v) = split /:\s*/, $line, 2;
        $v =~ s/[ \t]+\z// if defined $v;
        die 'Invalid HTTP headers' unless defined($v) && $k =~ /^[A-Za-z0-9!#$%&'*+.^_`|~-]+$/;
        die 'Ambiguous HTTP request length' if lc($k) eq 'content-length' && exists $h{'content-length'};
        $h{lc($k)} = $v;
    }
    # The local control API sends Content-Length JSON requests. Public streaming
    # and chunked traffic is handled separately by Proxy.
    die 'Incomplete HTTP headers' unless $complete;
    die 'Unsupported HTTP request framing' if exists $h{'transfer-encoding'};
    my $length=$h{'content-length'} // '0';
    die 'Invalid HTTP request length' unless $length =~ /\A[0-9]{1,12}\z/;
    my $len = 0+$length;
    die 'HTTP request body is too large' if $len>8*1024*1024;
    my $body = '';
    while (length($body) < $len) {
        my $n = read($sock, my $buf, $len - length($body));
        die 'Incomplete HTTP request body' unless defined($n) && $n>0;
        $body .= $buf;
    }
    return ($method, $path, \%h, $body);
}

1;
