package VisLlama::Paths;

# Resolve portable installation paths and model-root containment checks.
# Public asset access has its own stricter allowlist in Assets.
use strict;
use warnings;

use File::Spec;
use Cwd qw(abs_path);
use File::Basename qw(dirname);

# -----------------------------------------------------------------------------
# Security helper: verify a path remains under an allowed root.
# -----------------------------------------------------------------------------
sub canonical_under {
    my ($path, $root) = @_;
    return 0 unless defined $path && defined $root;
    # Keep the inherited Windows normalization. Linux resolves existing paths
    # before containment so .. and symlinks cannot escape the model library.
    if ($^O eq 'MSWin32') {
        my $p = lc(File::Spec->canonpath($path));
        my $r = lc(File::Spec->canonpath($root));
        $r =~ s/[\\\/]+$//;
        return index($p, $r . '\\') == 0 || $p eq $r;
    }
    my $p=abs_path($path);my $r=abs_path($root);
    return 0 unless defined $p && defined $r;
    return 1 if $r eq '/' && $p =~ m{^/};
    return $p eq $r || index($p,$r.'/')==0;
}

# Resolve once from this module, never from the caller's working directory.
my $BASE_DIR = File::Spec->rel2abs(dirname(dirname(dirname(__FILE__))));
# Return the installation root derived from this module, independent of cwd.
# Launchers, templates and persistent state therefore move together.
sub app_base_dir { return $BASE_DIR; }

# -----------------------------------------------------------------------------
# Return/create the persistent presets directory beside the script.
# -----------------------------------------------------------------------------
sub presets_dir {
    my $dir = File::Spec->catdir(app_base_dir(), 'presets');
    mkdir $dir unless -d $dir;
    return File::Spec->rel2abs($dir);
}

1;
