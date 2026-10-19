package VisLlama::ProxyResponse;
use strict;
use warnings;
use JSON::PP qw(encode_json decode_json);
use VisLlama::Errors ();

# Only this module handles upstream response framing. Never forward native error
# bodies, status reason text, custom headers or trailers into the public response.
# Successful model content is data, not diagnostics; do not redact its prose.
sub write_all {
    my ($sock,$bytes)=@_; my $offset=0;
    while ($offset<length($bytes)) {
        my $n=syswrite($sock,$bytes,length($bytes)-$offset,$offset);
        return 0 unless defined($n) && $n>0;
        $offset+=$n;
    }
    return 1;
}

sub envelope {
    my ($detail,$code)=@_;
    my $e=VisLlama::Errors::public_error($detail,$code||'backend_error');
    return {error=>{message=>$e->{message},type=>$e->{code},code=>$e->{code},reference=>$e->{reference}}};
}

sub send_error {
    my ($client,$status,$detail,$code,$started,$cors)=@_;
    $cors //= '';
    $status=502 unless $status =~ /^(?:400|401|403|404|408|409|413|422|429|500|502|503|504)$/;
    my $body=encode_json(envelope($detail,$code));
    $started->('json') if $started;
    return write_all($client,"HTTP/1.1 $status Request Failed\r\n${cors}Content-Type: application/json; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: ".length($body)."\r\nConnection: close\r\n\r\n$body");
}

# Preserve browser access policy without reflecting arbitrary native header text.
# A concrete origin is returned only if it equals the caller's validated origin.
sub cors_headers {
    my ($h,$origin)=@_;
    my $allow=$h->{'access-control-allow-origin'}//'';
    return '' unless $allow eq '*' || (defined($origin) && $allow eq $origin &&
        $origin =~ m{\Ahttps?://(?:[A-Za-z0-9.-]+|\[[0-9A-Fa-f:]+\])(?::[0-9]{1,5})?\z});
    my $out="Access-Control-Allow-Origin: $allow\r\n";
    $out.="Vary: Origin\r\n" unless $allow eq '*';
    for my $pair (['access-control-allow-methods','Access-Control-Allow-Methods',qr/^(?:\*|GET|POST|OPTIONS|HEAD|PUT|PATCH|DELETE)$/],
                  ['access-control-allow-headers','Access-Control-Allow-Headers',qr/^(?:\*|authorization|content-type|accept|origin|x-api-key|api-key|x-requested-with|cache-control)$/i]) {
        my @values=grep { /$pair->[2]/ } split /\s*,\s*/,($h->{$pair->[0]}//'');
        $out.="$pair->[1]: ".join(', ',@values)."\r\n" if @values;
    }
    $out.="Access-Control-Allow-Credentials: true\r\n" if $allow ne '*' && ($h->{'access-control-allow-credentials'}//'') eq 'true';
    return $out;
}

sub exact {
    my ($sock,$count,$reader)=@_; my $out='';
    while (length($out)<$count) {
        my $part;my $n;
        if($reader){$part=$reader->read($count-length($out));$n=length($part)}else{$n=read($sock,$part,$count-length($out))}
        die 'Truncated backend response' unless defined($n) && $n>0;
        $out.=$part;
    }
    return $out;
}

# Decode transfer framing before inspecting SSE/JSON. Stop promptly if a client
# disconnects or a diagnostic prefix has reached its cap. Trailers are discarded.
sub consume {
    my ($sock,$h,$accept,$reader)=@_;
    my $chunked=($h->{'transfer-encoding'}//'') =~ /chunked/i;
    if ($chunked) {
        while (1) {
            my $line=$reader?$reader->line():scalar(<$sock>); die 'Missing backend chunk header' unless defined $line;
            die 'Invalid backend chunk header' unless $line =~ /^([0-9a-fA-F]{1,12})(?:;[^\r\n]*)?\r?\n$/;
            my $n=hex($1);return 1 if !$n;
            while ($n>0) {
                my $take=$n>65536?65536:$n;my $part;my $got;if($reader){$part=$reader->read($take);$got=length($part)}else{$got=read($sock,$part,$take)};
                die 'Truncated backend chunk' unless defined($got) && $got>0;
                return 0 unless $accept->($part);$n-=$got;
            }
            die 'Invalid backend chunk ending' unless exact($sock,2,$reader) eq "\r\n";
        }
    } elsif (defined $h->{'content-length'}) {
        die 'Invalid backend response length' unless $h->{'content-length'} =~ /^\d{1,12}$/;
        my $n=0+$h->{'content-length'};
        while ($n>0) {
            my $take=$n>65536?65536:$n;my $part;my $got;if($reader){$part=$reader->read($take);$got=length($part)}else{$got=read($sock,$part,$take)};
            die 'Truncated backend response' unless defined($got) && $got>0;
            return 0 unless $accept->($part);$n-=$got;
        }
    } else {
        while (1) {my $part;my $n;if($reader){$part=$reader->read(65536);$n=length($part)}else{$n=read($sock,$part,65536)};die 'Backend read failed' unless defined $n;last unless $n;return 0 unless $accept->($part);}
    }
    return 1;
}

# Recognize only documented structured overflow codes; native prose stays private.
sub error_code {
    my ($obj,$fallback)=@_;
    my $error=ref($obj) eq 'HASH' ? $obj->{error} : undef;
    return $fallback unless ref($error) eq 'HASH';
    return 'context_size_exceeded' if ($error->{type}//'') eq 'exceed_context_size_error'
        || ($error->{code}//'') eq 'context_length_exceeded';
    return $fallback;
}
sub stream_event {
    my ($event)=@_;
    my (@data,$name);
    for my $line (split /\r\n|\r|\n/,$event) {
        push @data,$1 if $line =~ /^data: ?(.*)$/;
        $name=$1 if $line =~ /^event: ?(.*)$/;
    }
    # Comments and unrecognized metadata are not public diagnostic channels.
    return (": heartbeat\n\n",0) unless @data || defined($name);
    my $data=join("\n",@data);
    return ("data: [DONE]\n\n",0) if $data eq '[DONE]' && ($name//'') ne 'error';
    my $obj=eval { decode_json($data) };
    my $bad=$@ || ($name//'') eq 'error' || (ref($obj) eq 'HASH' &&
        (($obj->{error}) || ($obj->{type}//'') =~ /^(?:error|response\.failed)$/ ||
         (ref($obj->{response}) eq 'HASH' && $obj->{response}{error})));
    if ($bad) {return ("data: ".encode_json(envelope($event,error_code($obj,'stream_error')))."\n\n",1);}
    my $prefix=defined($name) && $name =~ /^(?:message|completion|done|ping|response\.(?:created|in_progress|completed|output_text\.delta|output_text\.done))$/ ? "event: $name\n" : '';
    return ($prefix.join('',map {"data: $_\n"} @data)."\n",0);
}

sub relay {
    my ($backend,$client,$method,$status,$h,$started,$origin,$reader)=@_;
    my $cors=cors_headers($h,$origin);
    die 'Invalid backend status' unless $status =~ m{^HTTP/1\.[01] (\d{3})(?: |\r|\n|$)};
    my $code=0+$1;
    if ($code<200 || $code>=300) {
        my $prefix='';
        # Collect a bounded prefix for private diagnostics, never for a client.
        eval { consume($backend,$h,sub {$prefix.=substr($_[0],0,32768-length($prefix));return length($prefix)<32768;},$reader) } unless $method eq 'HEAD';
        my $obj=eval {decode_json($prefix)};
        return send_error($client,$code,"Upstream HTTP $code: $status\n$prefix",error_code($obj,$code<500?'invalid_request_error':'backend_error'),$started,$cors);
    }
    die 'Unsupported compressed backend response' if ($h->{'content-encoding'}//'identity') !~ /^identity$/i;
    my $type=lc($h->{'content-type'}//'application/octet-stream');
    if ($method eq 'HEAD' || $code==204) {
        $started->('body');return write_all($client,"HTTP/1.1 $code OK\r\n${cors}Connection: close\r\n\r\n");
    }
    if ($type =~ m{^application/(?:json|[\w.+-]+\+json)(?:;|$)}) {
        my $body='';
        consume($backend,$h,sub {die 'Backend JSON exceeds 64 MiB' if length($body)+length($_[0])>64*1024*1024;$body.=$_[0];1},$reader);
        my $obj=eval { decode_json($body) };
        return send_error($client,502,"Invalid backend JSON: $@",'backend_error',$started,$cors) if $@;
        return send_error($client,502,$body,error_code($obj,'backend_error'),$started,$cors) if ref($obj) eq 'HASH' && ($obj->{error});
        $started->('json');
        return write_all($client,"HTTP/1.1 $code OK\r\n${cors}Content-Type: application/json; charset=utf-8\r\nContent-Length: ".length($body)."\r\nConnection: close\r\n\r\n$body");
    }
    if ($type =~ m{^text/event-stream(?:;|$)}) {
        $started->('sse');
        return 0 unless write_all($client,"HTTP/1.1 $code OK\r\n${cors}Content-Type: text/event-stream; charset=utf-8\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n");
        my $buffer='';my $stopped=0;
        consume($backend,$h,sub {
            $buffer.=$_[0];die 'Backend SSE event exceeds 8 MiB' if length($buffer)>8*1024*1024;
            while ($buffer =~ s/\A(.*?)(?:\r\n\r\n|\n\n|\r\r)//s) {
                my ($safe,$error)=stream_event($1);
                if (!write_all($client,$safe) || $error) {$stopped=1;return 0;}
            }
            return 1;
        },$reader);
        if (!$stopped && $buffer =~ /\S/) {my ($safe)=stream_event($buffer);return write_all($client,$safe);}
        return 1;
    }
    # Successful non-JSON payloads (e.g. audio) remain byte streams. Only known
    # media types are reflected; arbitrary header values/reason text are not.
    my ($media)=$type =~ m{\A((?:audio|image)/[a-z0-9.+-]+|application/octet-stream|text/plain)(?:;|$)};
    $media||='application/octet-stream';$started->('body');
    return 0 unless write_all($client,"HTTP/1.1 $code OK\r\n${cors}Content-Type: $media\r\nConnection: close\r\n\r\n");
    return consume($backend,$h,sub {write_all($client,$_[0])},$reader);
}
1;
