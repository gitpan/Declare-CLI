package Declare::CLI;
use strict;
use warnings;

use Carp qw/croak/;
use Scalar::Util qw/blessed/;
use List::Util qw/max/;

use Exporter::Declare qw{
    import
    gen_default_export
    default_export
};

our $VERSION = 0.005;

gen_default_export CLI_META => sub {
    my ( $class, $caller ) = @_;
    my $meta = $class->new();
    $meta->{class} = $caller;
    return sub { $meta };
};

default_export arg => sub {
    my ( $meta, @params ) = _parse_params( @_ );
    $meta->add_arg( @params );
};

default_export opt => sub {
    my ( $meta, @params ) = _parse_params( @_ );
    $meta->add_opt( @params );
};

default_export describe_opt => sub {
    my ( $meta, @params ) = _parse_params( @_ );
    $meta->describe( 'opt' => @params );
};

default_export describe_arg => sub {
    my ( $meta, @params ) = _parse_params( @_ );
    $meta->describe( 'arg' => @params );
};

default_export usage => sub {
    my ( $meta, @params ) = _parse_params( @_ );
    $meta->usage( @params );
};

default_export process_cli => sub {
    my $consumer = shift;
    my ( @cli ) = @_;
    my $meta = $consumer->CLI_META;
    return $meta->process_cli( $consumer, @cli );
};

sub _parse_params {
    my ($first, @params) = @_;

    my $ref = ref $first;
    my $type = blessed $first;

    return ( $first->CLI_META, @params )
        if ($type || !$ref) && eval { $first->can( 'CLI_META' ) };

    my $meta = eval { caller(2)->CLI_META };
    croak "Could not find meta data object: $@"
        unless $meta;

    return ( $meta, @_ );
}

sub class { shift->{class} }
sub args { shift->{args}  }
sub opts { shift->{opts}  }
sub _defaults { shift->{defaults}  }

sub new {
    my $class = shift;
    my %params = @_;
    my $self = bless { args => {}, opts => {}, defaults => {} } => $class;

    $self->add_arg( $_ => $params{args}->{$_} )
        for keys %{ $params{args} || {} };

    $self->add_arg( $_ => $params{opts}->{$_} )
        for keys %{ $params{opts} || {} };

    return $self;
}

sub describe {
    my $self = shift;
    my ( $type, $name, $desc ) = @_;

    my $meth = $type . 's';
    croak "No such $type '$name'"
        unless $self->$meth->{$name};

    $self->$meth->{$name}->{description} = $desc if $desc;

    return $self->$meth->{$name}->{description};
}

sub valid_arg_params {
    return qr/^(alias|description|handler)$/;
}

sub add_arg {
    my $self = shift;
    my ( $name, @params ) = @_;
    my %config = @params > 1 ? @params : (handler => $params[0]);

    croak "arg '$name' already defined"
        if $self->args->{$name};

    for my $prop ( keys %config ) {
        next if $prop =~ $self->valid_arg_params;
        croak "invalid arg property: '$prop'";
    }

    $config{name} = $name;
    $config{description} ||= "No Description.";

    croak "You must provide a handler"
        unless $config{handler};

    if ( exists $config{alias} ) {
        my $aliases = ref $config{alias} ?   $config{alias}
                                         : [ $config{alias} ];

        $config{_alias} = { map { $_ => 1 } @$aliases };

        for my $alias ( @$aliases ) {
            croak "Cannot use alias '$alias', name is already taken by another arg."
                if $self->args->{$alias};

            $self->args->{$alias} = \%config;
        }
    }

    $self->args->{$name} = \%config;
}

sub valid_opt_params {
    return qr/^(alias|list|bool|default|check|transform|description|trigger)$/;
}

sub add_opt {
    my $self = shift;
    my ( $name, %config ) = @_;

    croak "opt '$name' already defined"
        if $self->opts->{$name};

    for my $prop ( keys %config ) {
        next if $prop =~ $self->valid_opt_params;
        croak "invalid opt property: '$prop'";
    }

    $config{name} = $name;
    $config{description} ||= "No Description.";

    croak "'check' cannot be used with 'bool'"
        if $config{bool} && $config{check};

    croak "'transform' cannot be used with 'bool'"
        if $config{bool} && $config{transform};

    croak "opt properties 'list' and 'bool' are mutually exclusive"
        if $config{list} && $config{bool};

    if (exists $config{default}) {
        croak "References cannot be used in default, wrap them in a sub."
            if ref $config{default} && ref $config{default} ne 'CODE';
        $self->_defaults->{$name} = $config{default};
    }

    if ( exists $config{check} ) {
        my $ref = ref $config{check};
        croak "'$config{check}' is not a valid value for 'check'"
            if ($ref && $ref !~ m/^(CODE|Regexp)$/)
            || (!$ref && $config{check} !~ m/^(file|dir|number)$/);
    }

    if ( exists $config{alias} ) {
        my $aliases = ref $config{alias} ?   $config{alias}
                                         : [ $config{alias} ];

        $config{_alias} = { map { $_ => 1 } @$aliases };

        for my $alias ( @$aliases ) {
            croak "Cannot use alias '$alias', name is already taken by another opt."
                if $self->opts->{$alias};

            $self->opts->{$alias} = \%config;
        }
    }

    $self->opts->{$name} = \%config;
}

sub process_cli {
    my $self = shift;
    my ( $consumer, @cli ) = @_;

    my ( $opts, $args ) = $self->_parse_cli( @cli );

    # Add defaults for opts not provided
    for my $opt ( keys %{ $self->_defaults } ) {
        next if exists $opts->{$opt};
        my $val = $self->_defaults->{$opt};
        $opts->{$opt} = ref $val ? $val->() : $val;
    }

    for my $opt ( keys %$opts ) {
        my $values = $opts->{$opt};
        my $list;

        if ( ref $values && ref $values eq 'ARRAY' ) {
            $list = 1;
        }
        else {
            $list = 0;
            $values = [ $values ];
        }

        my $transform = $self->opts->{$opt}->{transform};
        my $trigger   = $self->opts->{$opt}->{trigger};

        $values = [ map { $consumer->$transform( $_ ) } @$values ]
            if $transform;

        $self->_validate( $opt, $values );

        $opts->{$opt} = $list ? $values : $values->[0];

        $consumer->$trigger( $opt, $opts->{$opt}, $opts )
            if $trigger;
    }

    $consumer->set_opts( $opts ) if $consumer->can( 'set_opts' );

    return $opts unless @$args;

    my $arg = shift @$args;
    my $handler = $self->args->{$arg}->{handler};
    return $consumer->$handler( $arg, $opts, @$args );
}

sub _parse_cli {
    my $self = shift;
    my ( @cli ) = @_;

    my $args = [];
    my $opts = {};
    my $no_opts = 0;

    while ( my $item = shift @cli ) {
        if ( $item eq '--' ) {
            $no_opts++;
        }
        elsif ( $item =~ m/^-+([^-=]+)(?:=(.+))?$/ && !$no_opts ) {
            my ( $key, $value ) = ( $1, $2 );

            my $name = $self->_item_name( 'option', $self->opts, $key );
            $value = $self->_opt_value(
                $name,
                $value,
                \@cli
            );

            if( $self->opts->{$name}->{list} ) {
                push @{$opts->{$name}} => @$value;
            }
            else {
                $opts->{$name} = $value;
            }
        }
        elsif ( @$args ) {
            push @$args => $item;
        }
        else {
            # First item gets resolved
            push @$args => $self->_item_name( 'argument', $self->args, $item );
        }
    }

    return ( $opts, $args );
}

sub _opt_value {
    my $self = shift;
    my ( $opt, $value, $cli ) = @_;

    my $spec = $self->opts->{$opt};

    if ( $spec->{bool} ) {
        return $value if defined $value;
        return $spec->{default} ? 0 : 1;
    }

    my $val = defined $value ? $value : shift @$cli;

    return $spec->{list} ? [ split /\s*,\s*/, $val ]
                         : $val;
}

sub _validate {
    my $self = shift;
    my ( $opt, $value ) = @_;
    my $spec = $self->opts->{$opt};

    my $check = $spec->{check};
    return unless $check;
    my $ref = ref $check || "";

    my @bad;

    if ( $ref eq 'Regexp' ) {
        @bad = grep { $_ !~ $check } @$value;
    }
    elsif ( $ref eq 'CODE' ) {
        @bad = grep { !$check->( $_ ) } @$value;
    }
    elsif ( $check eq 'file' ) {
        @bad = grep { ! -f $_ } @$value;
    }
    elsif ( $check eq 'dir' ) {
        @bad = grep { ! -d $_ } @$value;
    }
    elsif ( $check eq 'number' ) {
        @bad = grep { m/\D/ } @$value;
    }

    return unless @bad;
    my $type = $ref || $check;
    die "Validation Failed for '$opt=$type': " . join( ", ", @bad ) . "\n";
}

sub _item_name {
    my $self = shift;
    my ( $type, $hash, $key ) = @_;

    # Exact match
    return $hash->{$key}->{name}
        if $hash->{$key};

    my %matches = map { $hash->{$_}->{name} => 1 }
        grep { m/^$key/ }
            keys %{ $hash };
    my @matches = keys %matches;

    die "partial $type '$key' is ambiguous, could be: " . join( ", " => sort @matches ) . "\n"
        if @matches > 1;

    die "unknown option '$key'\n"
        unless @matches;

    return $matches[0];
}

sub usage {
    my $self = shift;

    my $arg_len = max map { length $_ } keys %{ $self->args };
    my $opt_len = max map { length $_ } keys %{ $self->opts };

    my %seen;
    my $opts = join "\n" => sort map {
        my $spec = $self->opts->{$_};
        my $name = $spec->{name};
        my $value = $spec->{bool} ? "" : $spec->{list} ? "XXX,..." : "XXX";

        $seen{$name}++ ? () : sprintf(
            "    -%-${opt_len}s %-7s    %s",
            $name,
            $value,
            $spec->{description}
        );
    } keys %{ $self->opts };

    %seen = ();
    my $cmds = join "\n" => sort map {
        my $spec = $self->args->{$_};
        my $name = $spec->{name};

        $seen{$name}++ ? () : sprintf(
            "    %-${arg_len}s    %s",
            $name,
            $spec->{description}
        );
    } keys %{ $self->args };

    return <<"    EOT";
Options:
$opts

Arguments:
$cmds

    EOT
}

1;

__END__

=pod

=head1 NAME

Declare::CLI - Declarative command line interface builder.

=head1 DESCRIPTION

This module can be used to build command line utilities. It will handle option
and argument parsing according to your declarations. It also provides tools for
usage statements.

=head1 SYNOPSIS

your_prog.pl

    #!/usr/bin/perl
    use strict;
    use warnings;
    use Your::Prog;

    my @results = Your::Prog->new->process_cli( @ARGV );

    print join "\n", @results;

Your/Prog.pl

    package Your::Prog;
    use strict;
    use warnings;

    use Declare::CLI;

    opt 'enable-X' => (
        bool => 1,
        description => "Include X"
    );
    opt config => (
        default => "$ENV{HOME}/.config/your_prog.conf"
        validate => 'file',
        description => 'the config file'
    );
    opt types => (
        list => 1,
        default => sub { [ 'txt', 'rtf', 'doc' ] },
        description => "File types on which to act",
    );

    arg filter => sub {
        my $self = shift;
        my ( $opts, $args ) = @_;
        my $types = { map { $_ => 1 } @{ $opts->{types}} };
        return grep {
            m/\..({3,4})$/;
            $1 && $types->{$1} ? 1 : 0;
        } @$args;
    };

    # Descriptions are displayed in usage.
    describe_arg filter => "Filters args to only show those specified in types";

    arg sort => (
        describe => "sort args",
        handler => sub {
            my $self = shift;
            my ( $opts, $args ) = @_;
            return sort @$args;
        };
    };

    arg help => sub {
        my $self = shift;
        my ( $opts, $args ) = @_;

        return (
            "Usage: $0 [OPTS] [COMMAND] [FILES]\n",
            $self->usage
        );
    };

Using it:

B<Note:> not all options are used here. Other options are for example only and
not really useful.

    # Show all options and args
    $ your_prod.pl help

    # Find all txt, jpg, and gif files in the current dir
    $ your_prog.pl -types txt,jpg,gif filter ./*

    # Sort files in the current dir
    $ your_prog.pl sort ./*

    # Options and arguments can be short form as well, the shortest unambiguous
    # match will be used. For instance if you have options tyaaaa and tybbbbb
    # you could use -tya and -tyb to set them. just -ty is ambiguous and will
    # fail.
    $ your_prog.pl -t txt,jpg,gif filt ./*

=head1 EXPORTS

=over 4

=item $meta = CLI_META()

=item $meta = $CLASS->CLI_META()

=item $meta = $obj->CLI_META()

Get the meta oject. Meta object will be returned in any usage, method on class,
method on object, or function.

=item arg 'NAME' => ( %PROPERTIES )

=item $obj->arg( 'NAME' => %PROPERTIES )

Can be used as function in class, or method on class/object.

Declare a new argument. See the L<ARGUMENT PROPERTIES> section for more
details.

=item opt 'NAME' => ( %PROPERTIES )

=item $obj->opt( 'NAME' => %PROPERTIES )

Can be used as function in class, or method on class/object.

Declare a new option. See the L<OPTION PROPERTIES> section for more
details.

=item describe_opt 'NAME' => "DESCRIPTION"

=item $obj->describe_opt( 'NAME' => "DESCRIPTION" )

Can be used as function in class, or method on class/object.

Used to add a description to an option that is already defined.

=item describe_arg 'NAME' => "DESCRIPTION

=item $obj->describe_arg( 'NAME' => "DESCRIPTION" )

Can be used as function in class, or method on class/object.

Used to add a description to an argument that is already defined.

=item $usage = usage()

=item $usage = $obj->usage()

Can be used as function in class, or method on class/object.

Get a usage string listing all options and arguments.

=item $result = $obj->process_cli( @ARGS )

Must be used as an object method.

Process some command line input. If an argument is provided as input the result
of it will be returned. If no argument is specified, the options hash is
returned.

=back

=head1 OPTION PROPERTIES

=over 4

=item alias => "ALIAS_NAME"

=item alias => [ "ALIAS_NAME", ... ]

Set aliases for the option. Any alias can be used to set the option. Aliases
can be used for partial matches (short form)

=item list => $FLAG

If true the option will hold a list of values. Values can be comma seperated,
or you can provide the option multiple times and each value will be added to
the others.

=item bool => $FLAG

If true the option can only have a true or false value, and will not accept an
argument in the '-option value' form. You can specify a true or false value
using the '-option=VAL' form. Normally however simply specifying the option
'-option' will set it to true. If you provide a default value that is true,
specifying the opton will negate that so that specifying the option on the
command line turns it off.

=item default => $VALUE

=item default => sub { [ @VALUES ] }

Specify the value that will be used by default when the option is not listed on
the command line.

=item description => $STRING

Provide a description for the option. This is used in the 'usage' output.

=item trigger => sub { ... }

This gets called when the option is set, even if it is set to the default
value. The the sub is called as a method on your instance. The method receives
3 arguments, the name of the option, the value set, and the hashref of
C<{ option => value } of all options processed so far. The return value is
ignored.

    trigger => sub {
        my $self = shift;
        my ( $name, $value, $opts ) = @_;
        ...
    },

=item transform => sub { ... }

This is called whenever the value is set, before any triggers. This sub allows
you to modify the value before it is assigned. For list params each value is
passed to the transform sub seperately. This sub is called as a method on the
instance. This method receives the value as its only argument.

=item check => ...

See L<OPTION "check" PROPERTY>

=back

=head2 OPTION "check" PROPERTY

The "check" option is used to validate inputs to options. You can provide a
regex, a coderef, or a couple of premade options.

=over 4

=item check => qr/.../

Validate the value(s) against a regex.

=item check => sub { ... }

Validate the value against the sub. The sub is called as a function, not a
method. The function receives only one argument, the value to be checked. In
list options each item is checked seperately.

=item check => 'file'

Validate that the value(s) are all valid files. (-f check)

=item check => 'dir'

Validate that the value(s) are all valid directories. (-f check)

=item check => 'number'

Validate that the value(s) are all numerical. (rejects values that contain a
character matched by qr/\D/).

=back

=head1 ARGUMENT PROPERTIES

=over 4

=item alias => "ALIAS_NAME"

=item alias => [ "ALIAS_NAME", ... ]

Set aliases for the argument. Any alias can be used to set the argument. Aliases
can be used for partial matches (short form)

=item description => "The Description"

Provide a description for the argument. This is used in the 'usage' output.

=item handler => sub { ... }

This is the sub that gets called if the argument is provided on the command
line. The sub is called as a method on your instance. This method is called
with 2+ argument, the name of the arg, the { option => value } hash, and the
rest of the arguments from the command line are the remaining arguments.

    handler => sub {
        my $self = shift;
        my ( $name, $options, @args ) = @_;
        ...
    },

=back

=head1 META OBJECT METHODS

You should rarely if ever need to access these directly.

=over 4

=item $meta = $meta_class->new( opts => {...}, args => {...} )

Create a new meta object.

=item $class = $meta->class

Get the class for which the meta object was constructed.

=item $args = $meta->args

Get the hashref of { arg => \%config }

=item $opts = $meta->opts

Get the hashref of { opt => \%config }

=item $regex = $meta->valid_arg_params

Get a regex that can be used to validate the options available for args.

=item $regex = $meta->valid_opt_params

Get a regex that can be used to validate the options available for opts.

=item $usage = $meta->usage

Get the usage information.

=item $result = $meta->process_cli( $INSTANCE, @ARGS )

Process the command line arguments on $INSTANCE.

=item $meta->describe( $TYPE, $NAME, $DESCRIPTION )

Add a description to an argument or option.

=item $meta->add_arg( $NAME => %PROPERTIES )

Add an argument.

=item $meta->add_opt( $NAME => %PROPERTIES )

Add an option.

=back

=head1 AUTHORS

Chad Granum L<exodist7@gmail.com>

=head1 COPYRIGHT

Copyright (C) 2012 Chad Granum

Declare-Opts is free software; Standard perl licence.

Declare-Opts is distributed in the hope that it will be useful, but WITHOUT
ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
FOR A PARTICULAR PURPOSE. See the license for more details.

=cut
