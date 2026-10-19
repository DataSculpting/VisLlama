package VisLlama::Platform::Linux;

# An unreaped direct child pins its PID/process-group identity. Never signal a
# saved PID without that ownership. Descendants must stay in the launched group;
# deliberately daemonized children require separate support.
use strict;
use warnings;
use POSIX qw(setsid WNOHANG _exit);
use Fcntl qw(F_GETFD F_SETFD FD_CLOEXEC);
use Time::HiRes qw(time);
use Encode qw(encode);
sub stat_row {
    my ($pid)=@_;
    open my $fh,'<:raw',"/proc/$pid/stat" or return undef;
    my $raw=<$fh>;close $fh;
    return undef unless $raw =~ /^\d+ \(.*\) (\S) (.*)$/;
    my ($state,$rest)=($1,$2);my @v=split / /,$rest;
    return {state=>$state,pgrp=>$v[1],start=>$v[18]};
}
sub launch {
    my ($class,$spec)=@_;
    die 'Invalid Linux launch specification' unless ref($spec) eq 'HASH' && ref($spec->{args}) eq 'ARRAY' && ref($spec->{env}) eq 'HASH';
    die 'Linux process ownership requires mounted /proc' unless stat_row($$);
    my @argv=map {utf8::is_utf8($_) ? encode('UTF-8',$_) : $_} ($spec->{exe},@{$spec->{args}});
    die 'Invalid Linux launch arguments' if grep {!defined($_)||ref($_)||/\0/} @argv;
    pipe(my $reader,my $writer) or die "Launch pipe failed: $!";
    fcntl($writer,F_SETFD,FD_CLOEXEC) or die "Launch pipe flags failed: $!";
    my $pid=fork();die "Launch fork failed: $!" unless defined $pid;
    if (!$pid) {
        close $reader;
        eval {
            my $session=setsid();
            die "setsid failed: $!" unless defined($session) && $session>=0;
            chdir($spec->{cwd}) or die "Launch working directory failed: $!";
            $ENV{$_}=utf8::is_utf8($spec->{env}{$_}) ? encode('UTF-8',$spec->{env}{$_}) : $spec->{env}{$_} for keys %{$spec->{env}};
            $SIG{$_}='DEFAULT' for qw(INT TERM HUP PIPE);
            open STDIN,'<','/dev/null' or die "Launch stdin failed: $!";
            open STDOUT,'>>:raw',$spec->{log} or die "Launch log failed: $!";
            open STDERR,'>&',\*STDOUT or die "Launch stderr failed: $!";
            # A fork inherits the controller's listener/client sockets. Close
            # every other descriptor so a child cannot keep management alive.
            opendir my $dh,'/proc/self/fd' or die "Launch descriptor scan failed: $!";
            my @fds=grep {/^[0-9]+$/ && $_>2 && $_!=fileno($writer) && $_!=fileno($dh)} readdir $dh;
            closedir $dh;
            POSIX::close($_) for @fds;
            exec {$argv[0]} @argv;
            die "Launch exec failed: $!";
        };
        print {$writer} $@;close $writer;_exit(127);
    }
    close $writer;
    my $error=do {local $/;<$reader>};close $reader;
    if (length($error//'')) {waitpid($pid,0);die $error;}
    my $row=stat_row($pid);
    # exec success closes the pipe; even a fast exited child remains our zombie.
    # Own the child even if procfs health becomes temporarily unreadable. No
    # waitpid has reaped it, so its identity remains pinned for later queries.
    return bless {pid=>$pid,start=>($row && $row->{pgrp}==$pid ? $row->{start} : undef),exit_file=>$spec->{exit_file}},$class;
}
sub GetProcessID { $_[0]{pid} }
sub verified {
    my ($self)=@_;my $row=stat_row($self->{pid});
    return undef unless $row && $row->{pgrp}==$self->{pid};
    $self->{start}=$row->{start} unless defined $self->{start};
    return undef unless $row->{start} eq $self->{start};
    return $row;
}
sub members {
    my ($self)=@_;opendir my $dh,'/proc' or return undef;
    my @ids=grep {/^[0-9]+$/ && $_!=$self->{pid}} readdir $dh;closedir $dh;
    my @alive;
    for my $pid (@ids) {my $r=stat_row($pid);push @alive,$pid if $r && $r->{pgrp}==$self->{pid} && $r->{state} !~ /^[ZX]$/;}
    return \@alive;
}
sub GetExitCode {
    my ($self)=@_;
    if (defined $self->{exit}) {$_[1]=$self->{exit};return 1;}
    my $row=$self->verified() or return 0;
    if ($row->{state} !~ /^[ZX]$/) {$_[1]=259;return 1;}
    my $members=$self->members();return 0 unless defined $members;
    if (@$members) {
        # The zombie leader still pins this group's identity while cleanup runs.
        kill 'KILL',-$self->{pid};$_[1]=259;return 1;
    }
    my $done=waitpid($self->{pid},WNOHANG);return 0 unless $done==$self->{pid};
    my $status=$?;
    $self->{exit}=($status & 127) ? 128+($status & 127) : $status >> 8;
    $self->{signal}=$status & 127;
    if ($self->{exit_file}) {
        open my $fh,'>:raw',$self->{exit_file} or die "Cannot write native exit status: $!";
        print {$fh} $self->{exit}."\n";close $fh;
    }
    $_[1]=$self->{exit};return 1;
}
sub stop {
    my ($self)=@_;return 1 if defined $self->{exit};
    return 0 unless $self->verified();
    for my $step (['TERM',1.0],['KILL',2.0]) {
        return 0 unless $self->verified();
        kill $step->[0],-$self->{pid};
        my $until=time()+$step->[1];
        while (time()<$until) {my $exit;return 1 if $self->GetExitCode($exit) && $exit!=259;select undef,undef,undef,0.03;}
    }
    return 0;
}
1;
