package VisLlama::Models;

# Server-side model discovery and folder browsing. Paths refer to the
# host running VisLlama, never to the browser machine.
use strict;
use warnings;

use File::Spec;
use Encode qw(decode FB_CROAK);
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use VisLlama::Platform ();

use VisLlama::Context qw(%CFG);
use VisLlama::Util qw(jtrue jfalse);

# -----------------------------------------------------------------------------
# Server-side file/folder browser used by the web UI.
# -----------------------------------------------------------------------------
sub list_server_folders {
    my ($path, $include_files) = @_;
    $path //= '';
    $path =~ s/^\s+|\s+$//g;
    if (!VisLlama::Platform::windows()) {
        return {path=>'',parent=>'',folders=>[{name=>'/',path=>'/'}],files=>[],roots=>jtrue} unless length $path;
        my $clean=abs_path($path);return undef unless defined($clean) && -d $clean;
        opendir my $dh,$clean or return undef;
        my (@folders,@files);
        for my $name (sort readdir $dh) {
            next if $name eq '.' || $name eq '..';
            $name=eval {decode('UTF-8',$name,FB_CROAK)};next unless defined $name;
            my $full=File::Spec->catfile($clean,$name);
            push @folders,{name=>$name,path=>$full} if -d $full;
            push @files,{name=>$name,path=>$full} if $include_files && -f $full;
        }
        closedir $dh;
        return {path=>$clean,parent=>$clean eq '/'?'':dirname($clean),folders=>\@folders,files=>\@files,roots=>jfalse};
    }
    if (!length $path) {
        my @drives;
        for my $letter ('A'..'Z') {
            my $root = $letter . ':\\';
            push @drives, { name=>$root, path=>$root } if -d $root;
        }
        return { path=>'', parent=>'', folders=>\@drives, files=>[], roots=>jtrue };
    }
    $path =~ tr{/}{\\};
    # A bare drive denotes its current directory on Windows, never its root.
    $path .= '\\' if $path =~ /\A[A-Za-z]:\z/;
    return undef unless -d $path;
    my $clean = $path;
    $clean =~ s/\\+$// unless $clean =~ /^[A-Za-z]:\\$/;
    opendir my $dh, $clean or return undef;
    my @names;
    my @file_names;
    while (defined(my $name = readdir $dh)) {
        next if $name eq '.' || $name eq '..';
        my $full = $clean;
        $full .= '\\' unless $full =~ /\\$/;
        $full .= $name;
        if (-d $full) { push @names, $name; }
        elsif ($include_files && -f $full) { push @file_names, $name; }
    }
    closedir $dh;
    @names = sort { lc($a) cmp lc($b) } @names;
    @file_names = sort { lc($a) cmp lc($b) } @file_names;
    my @folders = map {
        my $full = $clean;
        $full .= '\\' unless $full =~ /\\$/;
        $full .= $_;
        { name=>$_, path=>$full }
    } @names;
    my $parent = '';
    if ($clean !~ /^[A-Za-z]:$/ && $clean !~ /^[A-Za-z]:\\$/) {
        $parent = $clean;
        $parent =~ s/\\[^\\]+$//;
        $parent .= '\\' if $parent =~ /^[A-Za-z]:$/;
    }
    my @files = map { my $full = $clean; $full .= '\\' unless $full =~ /\\$/; $full .= $_; { name=>$_, path=>$full } } @file_names;
    return { path=>$clean, parent=>$parent, folders=>\@folders, files=>\@files, roots=>jfalse };
}

# -----------------------------------------------------------------------------
# Scan the supplier/variant GGUF hierarchy under the configured model root.
# -----------------------------------------------------------------------------
sub scan_models {
    my $root = $CFG{model_root};
    my @models;
    return \@models unless -d $root;

    require File::Find;
    File::Find::find({
        no_chdir => 1,
        wanted => sub {
            return unless -f $_;
            return unless /\.gguf$/i;
            my $full = $_;
            if (!VisLlama::Platform::windows() && !utf8::is_utf8($full)) {$full=eval {decode('UTF-8',$full,FB_CROAK)};return unless defined $full;}
            my $rel  = File::Spec->abs2rel($full, $root);
            my @parts = File::Spec->splitdir($rel);
            my $supplier = @parts >= 2 ? $parts[0] : '(root)';
            my $variant  = @parts >= 3 ? $parts[1] : '(unfiled)';
            push @models, {
                supplier => $supplier,
                variant  => $variant,
                file     => $parts[-1],
                path     => $full,
                rel      => $rel,
                size     => -s $full,
            };
        }
    }, $root);

    @models = sort {
        lc($a->{supplier}) cmp lc($b->{supplier}) ||
        lc($a->{variant})  cmp lc($b->{variant})  ||
        lc($a->{file})     cmp lc($b->{file})
    } @models;
    return \@models;
}

1;
