package VisLlama::Template;

# Minimal non-executable template rendering. Includes stay inside the private
# root, and substituted values are never evaluated as Perl or reparsed as templates.
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Spec;
use VisLlama::Util ();

# Deliberately small: escaped values, explicitly trusted HTML, and file includes.
# Templates are data, never executable Perl. The root is private to the server.
sub new {
    my ($class, $root) = @_;
    my $resolved = abs_path($root);
    die "Template directory is unavailable\n" unless defined $resolved && -d $resolved;
    return bless { root => $resolved }, $class;
}

sub render {
    my ($self, $name, $values, $trusted) = @_;
    return $self->_render($name, $values || {}, $trusted || {}, {});
}

sub _render {
    my ($self, $name, $values, $trusted, $stack) = @_;
    die "Invalid template name\n"
        unless defined $name && $name =~ m{\A(?:[A-Za-z0-9_-]+/)*[A-Za-z0-9_-]+\.html\z};
    die "Template include cycle or depth limit\n" if $stack->{$name} || keys(%$stack) >= 20;
    my $path = abs_path(File::Spec->catfile($self->{root}, split m{/}, $name));
    die "Template is unavailable\n" unless defined $path && -f $path;
    my $relative = File::Spec->abs2rel($path, $self->{root});
    die "Template is outside its directory\n"
        if File::Spec->file_name_is_absolute($relative) || $relative =~ m{\A\.\.(?:[/\\]|\z)};
    open my $fh, '<:encoding(UTF-8)', $path or die "Template is unavailable\n";
    local $/;
    my $html = <$fh> // '';
    close $fh;
    my %next = (%$stack, $name => 1);
    # A single substitution pass prevents values being interpreted as templates.
    $html =~ s{\{\{\{([A-Z][A-Z0-9_]*)\}\}\}|\{\{\s*>\s*([^{}]+?)\s*\}\}|\{\{([A-Z][A-Z0-9_]*)\}\}}{
        defined $1 ? _value($trusted, $1) :
        defined $2 ? $self->_render($2, $values, $trusted, \%next) :
        VisLlama::Util::html_escape(_value($values, $3))
    }gex;
    return $html;
}

sub _value {
    my ($values, $key) = @_;
    die "Missing template value\n" unless exists $values->{$key};
    return $values->{$key} // '';
}

1;
