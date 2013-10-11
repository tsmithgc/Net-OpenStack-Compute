package Net::OpenStack::Compute;
use Moose;

# VERSION

use Carp;
use HTTP::Request;
use JSON qw(from_json to_json);
use LWP;

has auth_url     => (is => 'rw', required => 1);
has user         => (is => 'ro', required => 1);
has password     => (is => 'ro', required => 1);
has project_id   => (is => 'ro');
has region       => (is => 'ro');
has service_name => (is => 'ro');
has is_rax_auth  => (is => 'ro');
has verify_ssl   => (is => 'ro', default => sub {! $ENV{OSCOMPUTE_INSECURE}});

has base_url => (
    is      => 'ro',
    lazy    => 1,
    default => sub { shift->_auth_info->{base_url} },
);
has token => (
    is      => 'ro',
    lazy    => 1,
    default => sub { shift->_auth_info->{token} },
);
has _auth_info => (is => 'ro', lazy => 1, builder => '_build_auth_info');

has _agent => (
    is => 'ro',
    lazy => 1,
    default => sub {
        my $self = shift;
        my $agent = LWP::UserAgent->new(
            ssl_opts => { verify_hostname => $self->verify_ssl });
        return $agent;
    },
);

with 'Net::OpenStack::Compute::AuthRole';

sub new_from_env {
    my ($self, %params) = @_;
    my $msg = "%s env var is required. Did you forget to source novarc?\n";
    die sprintf($msg, 'NOVA_URL or OS_AUTH_URL')
        unless $ENV{NOVA_URL} || $ENV{OS_AUTH_URL};
    die sprintf($msg, 'NOVA_USERNAME or OS_USERNAME')
        unless $ENV{NOVA_USERNAME} || $ENV{OS_USERNAME};
    die sprintf($msg, 'NOVA_PASSWORD or NOVA_API_KEY or OS_PASSWORD')
        unless $ENV{NOVA_PASSWORD} || $ENV{NOVA_API_KEY} || $ENV{OS_PASSWORD};
    my %env = (
        auth_url     => $ENV{NOVA_URL}         || $ENV{OS_AUTH_URL},
        user         => $ENV{NOVA_USERNAME}    || $ENV{OS_USERNAME},
        password     => $ENV{NOVA_PASSWORD}    || $ENV{NOVA_API_KEY}
                                               || $ENV{OS_PASSWORD},
        project_id   => $ENV{NOVA_PROJECT_ID}  || $ENV{OS_TENANT_NAME},
        region       => $ENV{NOVA_REGION_NAME} || $ENV{OS_AUTH_REGION},
        service_name => $ENV{NOVA_SERVICE_NAME},
        is_rax_auth  => $ENV{NOVA_RAX_AUTH},
    );
    return Net::OpenStack::Compute->new(%env, %params);
}

sub BUILD {
    my ($self) = @_;
    # Make sure trailing slashes are removed from auth_url
    my $auth_url = $self->auth_url;
    $auth_url =~ s|/+$||;
    $self->auth_url($auth_url);
}

sub _build_auth_info {
    my ($self) = @_;
    my $auth_info = $self->get_auth_info();
    $self->_agent->default_header(x_auth_token => $auth_info->{token});
    return $auth_info;
}

sub _get_query {
    my %params = @_;
    my $q = $params{query} or return '';
    for ($q) { s/^/?/ unless /^\?/ }
    return $q;
};

sub get_servers {
    my ($self, %params) = @_;
    my $q = _get_query(%params);
    my $res = $self->_get($self->_url("/servers", $params{detail}, $q));
    return from_json($res->content)->{servers};
}

sub get_server {
    my ($self, $id) = @_;
    croak "Invalid server id" unless $id;
    my $res = $self->_get($self->_url("/servers/$id"));
    return undef unless $res->is_success;
    return from_json($res->content)->{server};
}

sub get_servers_by_name {
    my ($self, $name) = @_;
    my $servers = $self->get_servers(detail => 1);
    return [ grep { $_->{name} eq $name } @$servers ];
}

sub create_server {
    my ($self, $data) = @_;
    croak "invalid data" unless $data and 'HASH' eq ref $data;
    croak "name is required" unless defined $data->{name};
    croak "flavorRef is required" unless defined $data->{flavorRef};
    croak "imageRef is required" unless defined $data->{imageRef};
    my $res = $self->_post("/servers", { server => $data });
    return from_json($res->content)->{server};
}

sub delete_server {
    my ($self, $id) = @_;
    $self->_delete($self->_url("/servers/$id"));
    return 1;
}

sub rebuild_server {
    my ($self, $server, $data) = @_;
    croak "server id is required" unless $server;
    croak "invalid data" unless $data and 'HASH' eq ref $data;
    croak "imageRef is required" unless $data->{imageRef};
    my $res = $self->_action($server, rebuild => $data);
    _check_res($res);
    return from_json($res->content)->{server};
}

sub resize_server {
    my ($self, $server, $data) = @_;
    croak "server id is required" unless $server;
    croak "invalid data" unless $data and 'HASH' eq ref $data;
    croak "flavorRef is required" unless $data->{flavorRef};
    my $res = $self->_action($server, resize => $data);
    return _check_res($res);
}

sub reboot_server {
    my ($self, $server, $data) = @_;
    croak "server id is required" unless $server;
    croak "invalid data" unless $data and 'HASH' eq ref $data;
    croak "reboot type is required" unless $data->{type};
    my $res = $self->_action($server, reboot => $data);
    return _check_res($res);
}

sub set_password {
    my ($self, $server, $password) = @_;
    croak "server id is required" unless $server;
    croak "password id is required" unless defined $password;
    my $res = $self->_action($server,
        changePassword => { adminPass => $password });
    return _check_res($res);
}

sub get_images {
    my ($self, %params) = @_;
    my $q = _get_query(%params);
    my $res = $self->_get($self->_url("/images", $params{detail}, $q));
    return from_json($res->content)->{images};
}

sub get_image {
    my ($self, $id) = @_;
    my $res = $self->_get($self->_url("/images/$id"));
    return undef unless $res->is_success;
    return from_json($res->content)->{image};
}

sub create_image {
    my ($self, $server, $data) = @_;
    croak "server id is required" unless defined $server;
    croak "invalid data" unless $data and 'HASH' eq ref $data;
    croak "name is required" unless defined $data->{name};
    my $res = $self->_action($server, createImage => $data);
    return _check_res($res);
}

sub delete_image {
    my ($self, $id) = @_;
    $self->_delete($self->_url("/images/$id"));
    return 1;
}

sub get_flavors {
    my ($self, %params) = @_;
    my $q = _get_query(%params);
    my $res = $self->_get($self->_url('/flavors', $params{detail}, $q));
    return from_json($res->content)->{flavors};
}

sub get_flavor {
    my ($self, $id) = @_;
    my $res = $self->_get($self->_url("/flavors/$id"));
    return undef unless $res->is_success;
    return from_json($res->content)->{flavor};
}

## VMS actions

# Launch a clone from a live image.
#
# Allowed params:
#
# 'name': Name of new server
# 'guest': Hash of guest parameters
# 'security_groups': List of security groups
# 'availability_zone': Nova availability zone
# 'scheduler_hints': Scheduler hints
# 'num_instances': Number of instances to launch
# 'key_name': Name of keypair
# 'user_data': base64 encoded user data
sub live_image_start {
    my ($self, $live_image, $data) = @_;
    croak "live image id is required" unless $live_image;
    croak "invalid data" unless $data and 'HASH' eq ref $data;
    my $res = $self->_action($live_image, gc_launch => $data);
    return from_json($res->content)->{servers};
}

# Create a new live image from a server.
#
# Allowed params:
#
# 'name': Name of live image. If not given, a
#         name will be auto-generated from the
#         name of the server.
sub live_image_create {
    my ($self, $server , $data) = @_;
    croak "server id is required" unless $server;
    croak "invalid data" unless $data and 'HASH' eq ref $data;
    my $res = $self->_action($server, gc_bless => $data);
    return from_json($res->content)->{servers};
}

# Discard a live image
#
sub live_image_delete {
    my ($self, $live_image) = @_;
    croak "live image id is required" unless $live_image;
    my $res = $self->_action($live_image, gc_discard => {});
    return _check_res($res);
}

# Migrate a VM, using VMS
#
# Allowed params:
#
# 'dest': Name of host to migrate to, as reported
#         by nova host-list.
sub live_migrate {
    my ($self, $live_image, $data) = @_;
    croak "live image id is required" unless $live_image;
    croak "invalid data" unless $data and 'hash' eq ref $data;
    my $res = $self->_action($live_image, gc_migrate => $data);
    return _check_res($res);
}

# List servers launched from a live image
#
sub list_launched {
    my ($self, $live_image) = @_;
    croak "live image id is required" unless $live_image;
    my $res = $self->_action($live_image, gc_list_launched => {});
    return from_json($res->content)->{servers};
}

# List live images for a server
#
sub list_blessed {
    my ($self, $server) = @_;
    croak "server id is required" unless $server;
    my $res = $self->_action($server, gc_list_blessed => {});
    return from_json($res->content)->{servers};
}

## End VMS actions

sub _url {
    my ($self, $path, $is_detail, $query) = @_;
    my $url = $self->base_url . $path;
    $url .= '/detail' if $is_detail;
    $url .= $query if $query;
    return $url;
}

sub _get {
    my ($self, $url) = @_;
    return $self->_agent->get($url);
}

sub _post {
    my ($self, $url, $data) = @_;
    return $self->_agent->post(
        $self->_url($url),
        content_type => 'application/json',
        content      => to_json($data),
    );
}

sub _delete {
    my ($self, $url) = @_;
    my $req = HTTP::Request->new(DELETE => $url);
    return $self->_agent->request($req);
}

sub _action {
    my ($self, $server, $action, $data) = @_;
    return $self->_post("/servers/$server/action", { $action => $data });
}

sub _check_res {
    my ($res) = @_;
    die $res->status_line . "\n" . $res->content
        if ! $res->is_success and $res->code != 404;
    return 1;
}

around qw( _get _post _delete ) => sub {
    my $orig = shift;
    my $self = shift;
    my $res = $self->$orig(@_);
    _check_res($res);
    return $res;
};


# ABSTRACT: Bindings for the OpenStack Compute API.

=head1 SYNOPSIS

    use Net::OpenStack::Compute;
    my $compute = Net::OpenStack::Compute->new(
        auth_url     => $auth_url,
        user         => $user,
        password     => $password,
        project_id   => $project_id,
        # Optional:
        region       => $ENV{NOVA_REGION_NAME},
        service_name => $ENV{NOVA_SERVICE_NAME},
        is_rax_auth  => $ENV{NOVA_RAX_AUTH},
        verify_ssl   => 0,
    );
    $compute->create_server({name => 's1', flavorRef => $flav_id, imageRef => $img_id});

=head1 DESCRIPTION

This class is an interface to the OpenStack Compute API.
Also see the L<oscompute> command line tool.

=head1 METHODS

Methods that take a hashref data param generally expect the corresponding
data format as defined by the OpenStack API JSON request objects.
See the
L<OpenStack Docs|http://docs.openstack.org/api/openstack-compute/1.1/content>
for more information.
Methods that return a single resource will return false if the resource is not
found.
Methods that return an arrayref of resources will return an empty arrayref if
the list is empty.
Methods that create, modify, or delete resources will throw an exception on
failure.

=head2 get_server

    get_server($id)

Returns the server with the given id or false if it doesn't exist.

=head2 get_servers

    get_servers(%params)

params:

=over

=item detail

Optional. Defaults to 0.

=item query

Optional query string to be appended to requests.

=back

Returns an arrayref of all the servers.

=head2 get_servers_by_name

    get_servers_by_name($name)

Returns an arrayref of servers with the given name.
Returns an empty arrayref if there are no such servers.

=head2 create_server

    create_server({ name => $name, flavorRef => $flavor, imageRef => $img_id })

Returns a server hashref.

=head2 delete_server

    delete_server($id)

Returns true on success.

=head2 rebuild_server

    rebuild_server($server_id, { imageRef => $img_id })

Returns a server hashref.

=head2 set_password

    set_password($server_id, $new_password)

Returns true on success.

=head2 get_image

    get_image($id)

Returns an image hashref.

=head2 get_images

    get_images(%params)

params:

=over

=item detail

Optional. Defaults to 0.

=item query

Optional query string to be appended to requests.

=back

Returns an arrayref of all the images.

=head2 create_image

    create_image($server_id, { name => 'bob' })

Returns an image hashref.

=head2 delete_image

    delete_image($id)

Returns true on success.

=head2 get_flavor

    get_flavor($id)

Returns a flavor hashref.

=head2 get_flavors

    get_flavors(%params)

params:

=over

=item detail

Optional. Defaults to 0.

=item query

Optional query string to be appended to requests.

=back

Returns an arrayref of all the flavors.

=head2 token

    token()

Returns the OpenStack Compute API auth token.

=head2 base_url

    base_url()

Returns the base url for the OpenStack Compute API, which is returned by the
server after authenticating.

=head1 SEE ALSO

=over

=item L<oscompute>

=item L<OpenStack Docs|http://docs.openstack.org/api/openstack-compute/1.1/content>

=back

=cut

1;
