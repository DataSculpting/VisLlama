package VisLlama::Builds;

# Discover and inspect each configured llama.cpp executable independently.
# Device IDs and help belong to that binary, not to a global llama.cpp version.
use strict;
use warnings;

use File::Spec;
use Encode qw(decode FB_CROAK);
use VisLlama::Platform ();
use VisLlama::Docker ();

use Cwd qw(abs_path);

use VisLlama::Context qw(%CFG);
use VisLlama::Util qw(jtrue jfalse);
use VisLlama::Errors ();
my %PLANNER_VERSION;

# One version probe per executable revision, independent of the user-facing
# build alias. Unknown/custom versions keep upper SWA budgets, not guessed savings.
sub planner_build_number {
    my ($exe)=@_;
    if (VisLlama::Docker::is_ref($exe)) {my $raw=checked_probe($exe,'--version');my ($n)=$raw=~/\b(?:version|build)\s*[:=#]?\s*b?(\d{3,})\b/i;return $n;}
    my @st=stat($exe);return undef unless @st;
    my $key=join(':',$exe,$st[7],$st[9]);
    return $PLANNER_VERSION{$key} if exists $PLANNER_VERSION{$key};
    my $raw=eval { checked_probe($exe,'--version') } // '';
    my ($number)=$raw=~/\b(?:version|build)\s*[:=#]?\s*b?(\d{3,})\b/i;
    %PLANNER_VERSION=() if keys(%PLANNER_VERSION)>64;
    return $PLANNER_VERSION{$key}=$number;
}

# -----------------------------------------------------------------------------
# Locate llama-server.exe within a configured llama.cpp build directory.
# -----------------------------------------------------------------------------
sub find_server_exe {
    my ($build_dir) = @_;
    return $build_dir if VisLlama::Docker::is_ref($build_dir) && $^O eq 'linux';
    my @candidates = (
        File::Spec->catfile($build_dir, VisLlama::Platform::server_name()),
        File::Spec->catfile($build_dir, 'bin', VisLlama::Platform::server_name()),
    );
    for my $p (@candidates) { return $p if -f $p && (VisLlama::Platform::windows() || -x $p); }
    opendir(my $dh, $build_dir) or return undef;
    my @dirs = grep { $_ ne '.' && $_ ne '..' } readdir($dh);
    closedir($dh);
    for my $d (@dirs) {
        my $p = File::Spec->catfile($build_dir, $d, VisLlama::Platform::server_name());
        return $p if -f $p && (VisLlama::Platform::windows() || -x $p);
    }
    return undef;
}

# -----------------------------------------------------------------------------
# Return configured build aliases with detected llama-server executables.
# -----------------------------------------------------------------------------
sub build_entries_payload {
    my @entries;
    for my $name (@{$CFG{build_order} || []}) {
        next unless exists $CFG{builds}{$name};
        my $dir = $CFG{builds}{$name};
        my $exe = find_server_exe($dir);
        push @entries, { name=>$name, alias=>$name, dir=>$dir, path=>$dir, exe=>$exe, available=>($exe ? jtrue : jfalse),
            (VisLlama::Docker::is_ref($dir)?(type=>'docker',image=>VisLlama::Docker::image($dir)):(type=>'native')) };
    }
    return \@entries;
}

# Scan a user-selected directory with explicit bounds, including its root.
sub discover_builds {
    my ($root) = @_;
    my @queue = ([$root, 0]);
    my (%seen, @found);
    my $visited = 0;
    while (@queue && $visited < 2500 && @found < 32) {
        my ($dir, $depth) = @{shift @queue};
        my $real = abs_path($dir);
        next unless defined $real && !$seen{VisLlama::Platform::path_key($real)}++;
        $visited++;
        my $exe = File::Spec->catfile($dir, VisLlama::Platform::server_name());
        push @found, { dir=>$dir, exe=>$exe } if -f $exe && (VisLlama::Platform::windows() || -x $exe);
        next if $depth >= 8;
        opendir my $dh, $dir or next;
        my @children = sort { lc($a) cmp lc($b) } grep { $_ ne '.' && $_ ne '..' } readdir($dh);
        closedir $dh;
        for my $child (@children) {
            if (!VisLlama::Platform::windows()) {$child=eval {decode('UTF-8',$child,FB_CROAK)};next unless defined $child;}
            my $path = File::Spec->catdir($dir, $child);
            push @queue, [$path, $depth + 1] if -d $path && !-l $path;
        }
    }
    return (\@found, (scalar(@queue) || @found >= 32) ? 1 : 0, $visited);
}

# Collect version information and optionally help/devices for a configured binary.
# Capabilities are advertised flags, not a guarantee that a model or GPU supports them.
my %PROBE_CACHE;
sub checked_probe {
    my ($exe,$flag)=@_;
    return VisLlama::Docker::probe($exe,$flag) if VisLlama::Docker::is_ref($exe);
    my @stat=stat($exe);my $key=join('|',$exe,$flag,map {defined($_)?$_:''} @stat[7,9]);
    return $PROBE_CACHE{$key} if ($flag eq '--help' || $flag eq '--version') && exists $PROBE_CACHE{$key};
    my $text=VisLlama::Util::capture_command($exe,$flag);
    my $exit=$?;
    die "Build probe $flag failed ($exit): $text" if $exit;
    %PROBE_CACHE=() if keys(%PROBE_CACHE)>64;
    $PROBE_CACHE{$key}=$text if $flag eq '--help' || $flag eq '--version';
    return $text;
}

sub build_probe {
    my ($exe, $full) = @_;
    my $version = checked_probe($exe, '--version');
    my $help = $full ? checked_probe($exe, '--help') : '';
    my $devices = $full ? checked_probe($exe, '--list-devices') : '';
    my ($build) = $version =~ /\b(?:build|b)\s*#?\s*(\d{3,})\b/i;
    ($build) = $version =~ /\bversion\s*[:=]?\s*b?(\d{3,})\b/i unless $build;
    my ($commit) = $version =~ /\b(?:commit|hash)\s*[:=]?\s*([0-9a-f]{7,40})\b/i;
    my ($compiler) = $version =~ /\b(?:compiler|built with)\s*[:=]?\s*([^\r\n]+)/i;
    my ($target) = $version =~ /\b(?:target|platform)\s*[:=]?\s*([^\r\n]+)/i;
    my @flags = map { $_->{flag} } @{parse_help($help)};
    my @capabilities = grep { my $f=$_; scalar grep { $_ eq $f } @flags }
        qw(--models-preset --models-max --fit --draft-model --draft-mtp --device --tensor-split);
    my @dev = @{parse_devices($devices)};
    my $backend = @dev ? join(', ', map { $_->{id} } @dev) : '';
    return {
        version=>substr($version, 0, 16000), help=>substr($help, 0, 80000),
        devices_raw=>substr($devices, 0, 16000), devices=>\@dev,
        capabilities=>\@capabilities, build=>$build, commit=>$commit,
        compiler=>$compiler, target=>$target,
        backend=>$backend, size=>(-s $exe), modified=>(stat($exe))[9],
        (VisLlama::Docker::is_ref($exe)?(type=>'docker',image=>VisLlama::Docker::image($exe),image_id=>VisLlama::Docker::resolve($exe)->{Id}):()),
    };
}

# -----------------------------------------------------------------------------
# Parse llama-server --help so Advanced controls follow the selected executable.
# -----------------------------------------------------------------------------
sub parse_help {
    my ($text) = @_;
    my @opts;
    my $current;
    for my $line (split /\r?\n/, $text) {
        if ($line =~ /^\s{1,}((?:-[^-\s][^\s,]*\s*,?\s*)?(?:--[A-Za-z0-9][A-Za-z0-9_-]*(?:\s*,\s*--?[A-Za-z0-9][A-Za-z0-9_-]*)*)(?:\s+[^\s].*?)?)\s{2,}(\S.*)$/) {
            my ($sig, $desc) = ($1, $2);
            my @long = ($sig =~ /(--[A-Za-z0-9][A-Za-z0-9_-]*)/g);
            next unless @long;
            my ($flag) = grep { $_ !~ /^--no-/ } @long;
            $flag ||= $long[0];
            my $after = $sig;
            $after =~ s/^.*\Q$long[-1]\E\s*//;
            $after =~ s/^,\s*//;
            my $takes = ($after ne '' && $after !~ /^--/) ? 1 : 0;
            $current = {
                flag => $flag,
                aliases => \@long,
                signature => $sig,
                description => $desc,
                takes_value => $takes ? jtrue : jfalse,
                value_hint => $takes ? $after : '',
            };
            push @opts, $current;
        } elsif ($current && $line =~ /^\s{8,}(\S.*)$/) {
            $current->{description} .= ' ' . $1;
        } else {
            $current = undef if $line =~ /^\S/;
        }
    }
    return \@opts;
}

# -----------------------------------------------------------------------------
# Parse llama-server --list-devices and return llama.cpp device IDs.
# -----------------------------------------------------------------------------
sub parse_devices {
    my ($text) = @_;
    my @devices;
    my %seen;
    for my $line (split /\r?\n/, $text // '') {
        # llama.cpp --list-devices currently emits entries such as:
        #   CUDA0: NVIDIA GeForce RTX 3060, 11997 MiB free
        # Keep the parser backend-agnostic enough for future device prefixes.
        if ($line =~ /^\s*([A-Za-z][A-Za-z0-9_.-]*\d+)\s*:\s*(.+?)\s*$/) {
            my ($id, $desc) = ($1, $2);
            next if $seen{lc $id}++;
            push @devices, { id => $id, description => $desc, raw => $line };
        }
    }
    return \@devices;
}

1;
