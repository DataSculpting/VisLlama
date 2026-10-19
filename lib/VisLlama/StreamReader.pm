package VisLlama::StreamReader;
# GPL-3.0-only. Buffered transport reads watch the downstream socket as well as
# upstream data. Aborting chat closes the upstream even during silent prefill.
use strict;
use warnings;
use IO::Select;
use Time::HiRes qw(time);
sub new {my ($class,$up,$down)=@_;bless {up=>$up,down=>$down,buffer=>'',last=>time(),eof=>0},$class}
sub fill {
    my ($s)=@_;return 0 if $s->{eof};
    my $select=IO::Select->new($s->{up},$s->{down});
    while (1) {
        die 'Inference stream idle timeout' if time()-$s->{last}>330;
        for my $sock ($select->can_read(0.2)) {
            if (fileno($sock)==fileno($s->{down})) {
                my $n=sysread($sock,my $ignored,1);
                die 'Inference client disconnected' unless defined($n) && $n>0;
                die 'Unexpected downstream data';
            }
            my $n=sysread($sock,my $part,65536);die 'Inference stream read failed' unless defined $n;
            if (!$n) {$s->{eof}=1;return 0;}
            $s->{last}=time();$s->{buffer}.=$part;return 1;
        }
    }
}
sub read {my ($s,$n)=@_;$s->fill unless length($s->{buffer}) || $s->{eof};return substr($s->{buffer},0,$n,'')}
sub line {
    my ($s)=@_;
    while (index($s->{buffer},"\n")<0 && !$s->{eof}) {
        die 'Inference header is too large' if length($s->{buffer})>65536;
        $s->fill;
    }
    return undef unless length($s->{buffer});
    my $end=index($s->{buffer},"\n");return substr($s->{buffer},0,$end<0?length($s->{buffer}):$end+1,'');
}
1;
