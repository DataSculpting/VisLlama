package VisLlama::Storage;

# GPL-3.0-only. Checked same-directory publication with a rollback journal.
# Native readers see whole individual files; cooperating readers also take the
# transaction lock. A set of files is recoverable, not one filesystem rename.
use strict;
use warnings;
use Fcntl qw(:DEFAULT :flock);
use File::Spec;
use File::Basename qw(dirname);
use File::Temp qw(tempfile);
use IO::Handle;
use Encode qw(encode);
use JSON::PP ();
use VisLlama::Paths ();
our $DEPTH=0;

sub journal_path { File::Spec->catfile(VisLlama::Paths::presets_dir(),'publication-journal.json') }
sub raw_read {
    my ($path)=@_;
    open my $fh,'<:raw',$path or die "Cannot read $path: $!";
    local $/;my $bytes=<$fh>;close($fh) or die "Cannot close $path: $!";
    return defined($bytes)?$bytes:'';
}
sub stage {
    my ($path,$bytes)=@_;
    my ($fh,$temp)=tempfile('.visllama-XXXXXXXX',DIR=>dirname($path),UNLINK=>0);
    my $ok=eval {
        binmode($fh,':raw') or die "Cannot set raw encoding: $!";
        print {$fh} $bytes or die "Cannot write staged file: $!";
        $fh->flush or die "Cannot flush staged file: $!";
        $fh->sync or die "Cannot sync staged file: $!";
        close($fh) or die "Cannot close staged file: $!";1;
    };
    if (!$ok) {my $error=$@;close $fh;unlink $temp;die $error;}
    return $temp;
}
sub sync_directory {
    my ($dir)=@_;return if $^O eq 'MSWin32';
    open my $fh,'<',$dir or die "Cannot open publication directory: $!";
    $fh->sync or die "Cannot sync publication directory: $!";close $fh;
}
sub windows_replace {
    my ($from,$to)=@_;require Win32API::File;
    Win32API::File::MoveFileExW(encode('UTF-16LE',$from."\0"),encode('UTF-16LE',$to."\0"),0x1|0x8)
        or die "Cannot replace $to: $^E";
}
sub replace_file {
    my ($from,$to)=@_;
    if ($^O eq 'MSWin32') {
        # REPLACE_EXISTING | WRITE_THROUGH. Use explicit Unicode paths.
        windows_replace($from,$to);
    } else { rename($from,$to) or die "Cannot replace $to: $!"; }
    sync_directory(dirname($to));
}
sub remove_file {my ($path)=@_;if(-e $path){unlink($path) or die "Cannot remove $path: $!";sync_directory(dirname($path));}}
sub atomic_bytes {
    my ($path,$bytes)=@_;my $temp=stage($path,$bytes);
    my $ok=eval {replace_file($temp,$path);1};my $error=$@;
    unlink $temp if -e $temp;die $error unless $ok;
}
sub rollback {
    my ($journal)=@_;
    die 'Invalid publication journal' unless ref($journal) eq 'HASH' && ref($journal->{files}) eq 'ARRAY';
    for my $entry (reverse @{$journal->{files}}) {
        die 'Invalid publication journal entry' unless ref($entry) eq 'HASH' && $entry->{path};
        if ($entry->{backup}) { atomic_bytes($entry->{path},raw_read($entry->{backup})); }
        else { remove_file($entry->{path}); }
    }
}
sub cleanup {
    my ($journal)=@_;
    # Remove the journal first. Orphan staging files are harmless; a surviving
    # journal always has all backups needed for another idempotent rollback.
    remove_file(journal_path());
    for my $entry (@{$journal->{files}}) {
        unlink $entry->{backup} if $entry->{backup} && -f $entry->{backup};
        unlink $entry->{staged} if $entry->{staged} && -f $entry->{staged};
    }
}
sub recover {
    return unless -f journal_path();
    my $journal=JSON::PP::decode_json(raw_read(journal_path()));
    rollback($journal);cleanup($journal);
}
sub with_lock {
    my ($code)=@_;
    return $code->() if $DEPTH;
    my $path=File::Spec->catfile(VisLlama::Paths::presets_dir(),'publication.lock');
    sysopen(my $lock,$path,O_RDWR|O_CREAT,0600) or die "Cannot open publication lock: $!";
    flock($lock,LOCK_EX) or die "Cannot lock publication: $!";
    local $DEPTH=1;
    recover();
    return $code->(); # lexical handle unlocks even when the callback throws
}
sub read {
    my ($path)=@_;
    return with_lock(sub {return undef unless -f $path;return raw_read($path)});
}
sub transaction {
    my ($entries)=@_;
    return with_lock(sub {
        my $journal={files=>[]};my %seen;
        my $ok=eval {
            for my $entry (@$entries) {
                my ($path,$bytes)=@$entry;$path=File::Spec->rel2abs($path);
                die 'Duplicate publication target' if $seen{lc $path}++;
                my $item={path=>$path};push @{$journal->{files}},$item;
                $item->{backup}=stage($path,raw_read($path)) if -f $path;
                $item->{staged}=stage($path,$bytes) if defined $bytes;
            }
            atomic_bytes(journal_path(),JSON::PP->new->ascii->canonical->encode($journal));
            for my $item (@{$journal->{files}}) {
                if ($item->{staged}) {replace_file($item->{staged},$item->{path});}
                else {remove_file($item->{path});}
            }
            # Journal removal is the commit point. Until then recovery restores
            # the old generation, including files already replaced successfully.
            cleanup($journal);1;
        };
        if (!$ok) {
            my $error=$@;
            if (-f journal_path()) {
                my $restored=eval {recover();1};
                die "$error\nPublication recovery incomplete: $@" unless $restored;
            } else {
                for my $item (@{$journal->{files}}) {
                    unlink $item->{backup} if $item->{backup};unlink $item->{staged} if $item->{staged};
                }
            }
            die $error;
        }
        return 1;
    });
}
sub write {my ($path,$bytes)=@_;transaction([[$path,$bytes]])}

# One controller may own this installation, regardless of its listen port.
# Advisory OS locks expire with the process; timestamps/PIDs never break a lock.
sub controller_lock {
    my $path=File::Spec->catfile(VisLlama::Paths::presets_dir(),'controller.lock');
    sysopen(my $fh,$path,O_RDWR|O_CREAT,0600) or die "Cannot open controller lock: $!";
    flock($fh,LOCK_EX|LOCK_NB) or die 'Another VisLlama controller owns this installation';
    return $fh;
}
1;
