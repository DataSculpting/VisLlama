package VisLlama::Assets;

# Serve only allowed public assets, plus the legacy image URL mappings.
# The application directory is not a static web root; modules and presets stay private.
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Spec;
use VisLlama::Paths ();
use VisLlama::HTTP ();

my %TYPES = (
    css => 'text/css; charset=utf-8', js => 'text/javascript; charset=utf-8',
    # The supplied favicon.ico contains PNG bytes; retain its original MIME type.
    png => 'image/png', ico => 'image/png', svg => 'image/svg+xml',
    jpg => 'image/jpeg', jpeg => 'image/jpeg', gif => 'image/gif',
    webp => 'image/webp', woff => 'font/woff', woff2 => 'font/woff2',
);
my %LEGACY_IMAGES = map { ('/' . $_) => '/assets/img/' . $_ } qw(
    visllama-logo.png visllama-logo-large.png visllama-logo.svg
    visllama-logo-32x32.png visllama-logo-16x16.png
    datasculpting-logo-ico.png favicon.ico favicon.png
);

sub serve {
    my ($sock, $url) = @_;
    $url = $LEGACY_IMAGES{$url} if exists $LEGACY_IMAGES{$url};
    # There is no file serving from the installation root. Encoded separators,
    # traversal, hidden files and directories are rejected, not normalized away.
    return VisLlama::HTTP::fail_json($sock, 'Not found', 404)
        unless $url =~ m{\A/assets/((?:[A-Za-z0-9_-]+/)*[A-Za-z0-9_-][A-Za-z0-9_.-]*\.([A-Za-z0-9]+))\z};
    my ($relative, $extension) = ($1, lc $2);
    my $type = $TYPES{$extension};
    return VisLlama::HTTP::fail_json($sock, 'Not found', 404) unless $type;
    my $root = abs_path(File::Spec->catdir(VisLlama::Paths::app_base_dir(), 'public', 'assets'));
    return VisLlama::HTTP::fail_json($sock, 'Asset not found', 404) unless defined $root;
    my $path = abs_path(File::Spec->catfile($root, split m{/}, $relative));
    return VisLlama::HTTP::fail_json($sock, 'Asset not found', 404) unless defined $path && -f $path;
    my $resolved = File::Spec->abs2rel($path, $root);
    return VisLlama::HTTP::fail_json($sock, 'Not found', 404)
        if File::Spec->file_name_is_absolute($resolved) || $resolved =~ m{\A\.\.(?:[/\\]|\z)};
    return VisLlama::HTTP::file_response($sock, $path, $type);
}

1;
