#!/usr/bin/perl -w
###############################################################################
# $Id: openstack.pm 2012-4-14
###############################################################################
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
###############################################################################

=head1 NAME

VCL::Provisioning::openstack - VCL module to support the Openstack provisioning engine

=head1 SYNOPSIS

 Needs to be written

=head1 DESCRIPTION

This module provides VCL support for Openstack

=cut

##############################################################################
package VCL::Module::Provisioning::openstack;

# Include File Copying for Perl
use File::Copy;

# Specify the lib path using FindBin
use FindBin;
use lib "$FindBin::Bin/../../..";
use Regexp::Common qw/net/;
use Net::OpenStack::Compute;
use Try::Tiny;

# Configure inheritance
use base qw(VCL::Module::Provisioning);

# Specify the version of this module
our $VERSION = '2.2.1';

# Specify the version of Perl to use
use 5.008000;

use strict;
use warnings;
use diagnostics;

use VCL::DataStructure;
use VCL::utils;

use Fcntl qw(:DEFAULT :flock);

#/////////////////////////////////////////////////////////////////////////////

=head2 initialize

 Parameters  :
 Returns :
 Description :

=cut

sub initialize {
	my $self = shift;
	notify($ERRORS{'DEBUG'}, 0, "OpenStack module initialized");

	if ($self->_set_openstack_user_conf) {
		notify($ERRORS{'OK'}, 0, "Success to OpenStack user configuration");
	}
	else {
		notify($ERRORS{'CRITICAL'}, 0, "Failure to Openstack user configuration");
		return 0;
	}

	return 1;
} ## end sub initialize

#/////////////////////////////////////////////////////////////////////////////

=head2 provision

 Parameters  : hash
 Returns : 1(success) or 0(failure)
 Description : loads virtual machine with requested image

=cut

sub load {
	my $self = shift;

	#check to make sure this call is for the openstack module
	if (ref($self) !~ /openstack/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return 0;
	}

	notify($ERRORS{'OK'}, 0, "****************************************************");

	# get various useful vars from the database
	my $image_full_name  = $self->data->get_image_name;
	my $computer_shortname   = $self->data->get_computer_short_name;
	my $request_forimaging   = $self->data->get_request_forimaging();

	# power off the old instance if exists
	$self->_terminate_instances;	

	# Create new instance
	my $instance = $self->_run_instances;
	my $instance_id;

	if ($instance) {
		$instance_id = $instance->{id};
		notify($ERRORS{'OK'}, 0, "The instance $instance_id has been created\n");
	}
	else {
		notify($ERRORS{'CRITICAL'}, 0, "Failed to run the instance");
		return 0;
	}

	# Update the private ip of the instance in /etc/hosts file
	if ($self->_update_private_ip($instance_id)) {
		notify($ERRORS{'OK'}, 0, "Updated the private ip of instance $instance_id");
	}
	else {
		notify($ERRORS{'CRITICAL'}, 0, "Failed to update private ip of the instance in /etc/hosts");
		return 0;
	}

	# Instances have the ip instantly when it use FlatNetworkManager
	# Need to wait for copying images from repository or cache to instance directory
	# 15G for 3 to 5 minutes (depends on systems)
	#sleep 300;
	sleep 100;

	# Call post_load
	if ($self->os->can("post_load")) {
		notify($ERRORS{'DEBUG'}, 0, "calling " . ref($self->os) . "->post_load()");
		if ($self->os->post_load()) {
			notify($ERRORS{'DEBUG'}, 0, "successfully ran OS post_load subroutine");
		}
		else {
			notify($ERRORS{'WARNING'}, 0, "failed to run OS post_load subroutine");
			return;
		}
	}
	else {
		notify($ERRORS{'DEBUG'}, 0, ref($self->os) . "::post_load() has not been implemented");
	}

	return 1;

} ## end sub load

#/////////////////////////////////////////////////////////////////////////////

=head2 capture

 Parameters  : $request_data_hash_reference
 Returns : 1 if sucessful, 0 if failed
 Description : Creates a new vmware image.

=cut

sub capture {
	notify($ERRORS{'DEBUG'}, 0, "**********************************************************");
	notify($ERRORS{'OK'},0, "Entering Openstack Capture routine");
	my $self = shift;

	if (ref($self) !~ /openstack/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return 0;
	}

	my $image_name = $self->data->get_image_name();
	my $computer_shortname = $self->data->get_computer_short_name;
	my $instance_id;

	if (_pingnode($computer_shortname)) {
		$instance_id = $self->_get_instance_id;

		if (!$instance_id) {
			notify($ERRORS{'DEBUG'}, 0, "Unable to get instance id for $computer_shortname");
			return 0;
		}
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "Unable to ping to $computer_shortname");
		return 0;
	}

	if ($self->_prepare_capture) {
		notify($ERRORS{'OK'}, 0, "Prepare_Capture for $computer_shortname is done");
	}

	my $openstack_image_id = $self->_image_create($instance_id);

	if (!$openstack_image_id) {
		notify($ERRORS{'CRITICAL'}, 0, "Nova create image request failed");
		return 0;
	}

	if (!$self->_insert_openstack_image_name($openstack_image_id)) {
		notify($ERRORS{'CRITICAL'}, 0, "Database insert failed");
		return 0;
	}

	if (!$self->_wait_for_copying_image($openstack_image_id)) {
		notify($ERRORS{'CRITICAL'}, 0, "Image copying failed");
	}

	return 1;
} ## end sub capture

sub _image_create{
	my $self = shift;
	my $instance_id = shift;
	my $imagerevision_comments = $self->data->get_imagerevision_comments(0);
	my $image_name = $self->data->get_image_name();

	my $image_description = $image_name . '-' . $imagerevision_comments;
	notify($ERRORS{'OK'}, 0, "Capturing instance $instance_id for $image_description");

	try {
		$self->{compute}->create_image($instance_id, { name => $image_description});
		notify($ERRORS{'OK'}, 0, "Image capture initiated");
	}
	catch {
		notify($ERRORS{'WARNING'}, 0, "Failed to capture image: $_");
		return 0;
	};

	sleep 10;

	my $images = $self->{compute}->get_images({ server => $instance_id });
	my $openstack_image_id = ${$images}[0]->{id};

	return $openstack_image_id;
}

sub _get_instance_id {
	my $self = shift;
	my $computer_id = $self->data->get_computer_id;

	my $select_statement = "
	SELECT
	instanceid
	FROM
	openstackComputerMap
	WHERE
	computerid = '$computer_id'
	";

	notify($ERRORS{'OK'}, 0, "$select_statement");
	my @selected_rows = database_select($select_statement);

	if (scalar @selected_rows == 0) {
		return 0;
	}

	my $instance_id = $selected_rows[0]{instanceid};
	notify($ERRORS{'OK'}, 0, "Openstack id for $computer_id is $instance_id");

	return $instance_id;
}

sub _prepare_capture {
	my $self = shift;

	my ($package, $filename, $line, $sub) = caller(0);
	my $request_data = $self->data->get_request_data;

	if (!$request_data) {
		notify($ERRORS{'WARNING'}, 0, "unable to retrieve request data hash");
		return 0;
	}

	my $request_id = $self->data->get_request_id;
	my $reservation_id = $self->data->get_reservation_id;
	my $management_node_keys = $self->data->get_management_node_keys();

	my $image_id   = $self->data->get_image_id;
	my $image_os_name  = $self->data->get_image_os_name;
	my $image_identity = $self->data->get_image_identity;
	my $image_os_type  = $self->data->get_image_os_type;
	my $image_name = $self->data->get_image_name();

	my $computer_id	= $self->data->get_computer_id;
	my $computer_shortname = $self->data->get_computer_short_name;
	my $computer_nodename  = $computer_shortname;
	my $computer_hostname  = $self->data->get_computer_hostname;
	my $computer_type  = $self->data->get_computer_type;

	if (write_currentimage_txt($self->data)) {
		notify($ERRORS{'OK'}, 0, "currentimage.txt updated on $computer_shortname");
	}
	else {
		notify($ERRORS{'DEBUG'}, 0, "unable to update currentimage.txt on $computer_shortname");
		return 0;
	}

	$self->data->set_imagemeta_sysprep(0);
	notify($ERRORS{'OK'}, 0, "Set the imagemeta Sysprep value to 0");

	if ($self->os->can("pre_capture")) {
		notify($ERRORS{'OK'}, 0, "calling OS module's pre_capture() subroutine");

		if (!$self->os->pre_capture({end_state => 'on'})) {
			notify($ERRORS{'DEBUG'}, 0, "OS module pre_capture() failed");
			return 0;
		}
	}
	return 1;
}

sub _insert_openstack_image_name {

	my $self = shift;
	my $openstack_image_name = shift;
	my $image_name = $self->data->get_image_name();

	my $insert_statement = "
	INSERT INTO
	openstackImageNameMap (
	  openstackImageNameMap.openstackimagename,
	  openstackImageNameMap.vclimagename
	) VALUES (
	  '$openstack_image_name',
	  '$image_name')";

	notify($ERRORS{'OK'}, 0, "$insert_statement");

	my $requested_id = database_execute($insert_statement);
	notify($ERRORS{'OK'}, 0, "SQL Insert is first time or requested_id : $requested_id");

	if ($requested_id) {
		notify($ERRORS{'OK'}, 0, "Successfully insert image name");
		return 1;
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "Unable to insert image name");
		return 0;
	}
}

sub _insert_instance_id {
	my $self = shift;
	my $instance_id = shift;
	my $computer_id = $self->data->get_computer_id;

	my $insert_statement = "
	INSERT INTO
	openstackComputerMap (
	  instanceid,
	  computerid
	) VALUES (
	  '$instance_id',
	  '$computer_id'
	)";

	notify($ERRORS{'OK'}, 0, "$insert_statement");
	my $success = database_execute($insert_statement);

	if ($success) {
		notify($ERRORS{'OK'}, 0, "Successfully inserted instance id");
		return 1;
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "Unable to insert instance id");
		return 0;
	}
}

sub _delete_computer_mapping {
	my $self = shift;
	my $computer_id = $self->data->get_computer_id;

	my $delete_statement = "
	DELETE FROM
	openstackComputerMap
	WHERE
	computerid='$computer_id'
	";

	notify($ERRORS{'OK'}, 0, "$delete_statement");
	my $success = database_execute($delete_statement);

	if ($success) {
		notify($ERRORS{'OK'}, 0, "Successfully deleted computer mapping");
		return 1;
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "Unable to delete computer mapping");
		return 0;
	}
}

sub _wait_for_copying_image {
	my $self = shift;

	my $openstack_image_id = shift;

	my $image_details = $self->{compute}->get_image($openstack_image_id);
	my $status;

	if (!$image_details) {
		notify($ERRORS{'WARNING'}, 0, "Get image request failed");
		return 0;
	}

	$status = $image_details->{status};

	my $loop = 150;

	notify($ERRORS{'OK'}, 0, "The status for $openstack_image_id: $status");
	while ($loop > 0) {
		if ($status eq 'ACTIVE') {
			notify($ERRORS{'OK'}, 0, "$openstack_image_id is available now");
			last;
		}
		elsif ($status eq 'SAVING') {
			notify($ERRORS{'OK'}, 0, "Sleep to capture New Image for 25 secs");
			sleep 25;
		}
		else {
			notify($ERRORS{'WARNING'}, 0, "Failure for $openstack_image_id");
			return 0;
		}

		$image_details = $self->{compute}->get_image($openstack_image_id);
		$status = $image_details->{status};
		notify($ERRORS{'OK'}, 0, "Status of image for loop #$loop: $status");
		$loop--;
	}

	if ($status ne 'ACTIVE') {
		notify($ERRORS{'WARNING'}, 0, "Timed out waiting for image to become available");
		return 0;
	}

	#notify($ERRORS{'OK'}, 0, "Sleep until image is available");
	sleep 30;

	return 1;
}

#/////////////////////////////////////////////////////////////////////////

=head2 node_status

 Parameters  : $nodename, $log
 Returns : array of related status checks
 Description : checks on sshd, currentimage

=cut

sub node_status {
	my $self = shift;

	my ($package, $filename, $line, $sub) = caller(0);

	my $vmpath	 = 0;
	my $datastorepath  = 0;
	my $vcl_requestedimagename = 0;
	my $requestedimagename = 0;
	my $vmhost_type	= 0;
	my $vmhost_hostname= 0;
	my $vmhost_imagename   = 0;
	my $image_os_type  = 0;
	my $vmclient_shortname = 0;
	my $request_forimaging = 0;
	my $identity_keys  = 0;
	my $log		= 0;
	my $computer_node_name = 0;

	# Set IAAS Environment
	notify($ERRORS{'OK'}, 0, "Set OpenStack Environment");

	# Check if subroutine was called as a class method
	if (ref($self) !~ /openstack/i) {
		notify($ERRORS{'OK'}, 0, "subroutine was called as a function");
		if (ref($self) eq 'HASH') {
			$log = $self->{logfile};
			#notify($ERRORS{'DEBUG'}, $log, "self is a hash reference");
			$vcl_requestedimagename = $self->{imagerevision}->{imagename};
			$image_os_type  = $self->{image}->{OS}->{type};
			$computer_node_name = $self->{computer}->{hostname};
			$identity_keys  = $self->{managementnode}->{keys};

		} ## end if (ref($self) eq 'HASH')
		# Check if node_status returned an array ref
		elsif (ref($self) eq 'ARRAY') {
			notify($ERRORS{'DEBUG'}, $log, "self is a array reference");
		}

		$vmclient_shortname = $1 if ($computer_node_name =~ /([-_a-zA-Z0-9]*)(\.?)/);
	} ## end if (ref($self) !~ /esx/i)
	else {
		# try to contact vm
		# $self->data->get_request_data;
		# get state of vm
		$vcl_requestedimagename = $self->data->get_image_name;
		$image_os_type  = $self->data->get_image_os_type;
		$vmclient_shortname = $self->data->get_computer_short_name;
		$request_forimaging = $self->data->get_request_forimaging();
		$identity_keys  = $self->data->get_management_node_keys;
	} ## end else [ if (ref($self) !~ /esx/i)

	notify($ERRORS{'OK'}, 0, "Entering node_status, checking status of $vmclient_shortname");
	notify($ERRORS{'OK'}, 0, "request_for_imaging: $request_forimaging");
	notify($ERRORS{'OK'}, 0, "requeseted image name: $vcl_requestedimagename");

	my ($hostnode);

	# Create a hash to store status components
	my %status;

	# Initialize all hash keys here to make sure they're defined
	$status{status}   = 0;
	$status{currentimage} = 0;
	$status{ping}	 = 0;
	$status{ssh}	  = 0;
	$status{vmstate}  = 0;	#on or off
	$status{image_match}  = 0;

	# Check if node is pingable
	notify($ERRORS{'OK'}, 0, "checking if $vmclient_shortname is pingable");
	if (_pingnode($vmclient_shortname)) {
		$status{ping} = 1;
		notify($ERRORS{'OK'}, 0, "$vmclient_shortname is pingable ($status{ping})");
	}
	else {
		notify($ERRORS{'OK'}, 0, "$vmclient_shortname is not pingable ($status{ping})");
		return $status{status};
	}

	notify($ERRORS{'DEBUG'}, 0, "Trying to ssh...");

	#can I ssh into it
	my $sshd = _sshd_status($vmclient_shortname, $vcl_requestedimagename, $image_os_type);

	#is it running the requested image
	if ($sshd eq "on") {

		notify($ERRORS{'DEBUG'}, 0, "SSH good, trying to query image name");

		$status{ssh} = 1;
		my @sshcmd = run_ssh_command($vmclient_shortname, $identity_keys, "cat currentimage.txt");
		$status{currentimage} = $sshcmd[1][0];

		notify($ERRORS{'DEBUG'}, 0, "Image name: $status{currentimage}");

		if ($status{currentimage}) {
			chomp($status{currentimage});
			if ($status{currentimage} =~ /$vcl_requestedimagename/) {
				$status{image_match} = 1;
				notify($ERRORS{'OK'}, 0, "$vmclient_shortname is loaded with requestedimagename $vcl_requestedimagename");
			}
			else {
				notify($ERRORS{'OK'}, 0, "$vmclient_shortname reports current image is currentimage= $status{currentimage} requestedimagename= $vcl_requestedimagename");
			}
		} ## end if ($status{currentimage})
	} ## end if ($sshd eq "on")

	# Determine the overall machine status based on the individual status results
	if ($status{ssh} && $status{image_match}) {
		$status{status} = 'READY';
	}
	else {
		$status{status} = 'RELOAD';
	}

	notify($ERRORS{'DEBUG'}, 0, "status set to $status{status}");

	if ($request_forimaging) {
		$status{status} = 'RELOAD';
		notify($ERRORS{'OK'}, 0, "request_forimaging set, setting status to RELOAD");
	}

	notify($ERRORS{'DEBUG'}, 0, "returning node status hash reference (\$node_status->{status}=$status{status})");
	return \%status;

} ## end sub node_status

sub does_image_exist {
	my $self = shift;
	if (ref($self) !~ /openstack/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return 0;
	}

	my $image_fullname = $self->data->get_image_name();
	my $image_os_type  = $self->data->get_image_os_type;

	# Match image name between VCL database and openstack Hbase database
	my $openstack_image_id = _match_image_name($image_fullname);
	my $image = $self->{compute}->get_image($openstack_image_id);

	if (!$image) {
		notify($ERRORS{'WARNING'}, 0, "The Image $openstack_image_id does NOT exists");
		return 0;
	}
	else {
		notify($ERRORS{'OK'}, 0, "The Image $openstack_image_id exists");
		return 1;
	}

} ## end sub does_image_exist

#/////////////////////////////////////////////////////////////////////////////

=head2  getimageflavor

 Parameters  : imagename
 Returns : 0 failure or flavor type
 Description : flavor type

=cut

sub _get_image_flavor {
	my $self = shift;
	if (ref($self) !~ /open/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return 0;
	}

	my $os_image_name = shift;

	#
	# Grab the config again, not sure this is a good way to do this
	#
	notify($ERRORS{'OK'}, 0, "********* Set OpenStack User Configuration******************");
	my $computer_shortname   = $self->data->get_computer_short_name;
	notify($ERRORS{'OK'}, 0,  "computer_shortname: $computer_shortname");
	# User's environment file
	my $user_config_file = '/etc/vcl/openstack/openstack.conf';
	notify($ERRORS{'OK'}, 0,  "loading $user_config_file");
	my %config = do($user_config_file);
	if (!%config) {
		notify($ERRORS{'CRITICAL'},0, "failure to process $user_config_file");
		return 0;
	}
	$self->{config} = \%config;

	#
	# Get the default flavor from the config file
	#
	my $os_default_flavor = $self->{config}->{os_default_flavor};

	notify($ERRORS{'OK'}, 0, "No image size information in Openstack");

	# XXX NOTE: The like part of this statement will cause issues if there is more than one version
	#	   of an image, which I don't think there should be -- Curtis XXX
	my $select_statement = "
	SELECT
	flavor
	FROM
	openstackImageNameMap
	WHERE
	openstackimagename like '$os_image_name%'
	";

	notify($ERRORS{'OK'}, 0, "flavor select_statement: $select_statement");
	# Call the database select subroutine
	# This will return an array of one or more rows based on the select statement
	my @selected_rows = database_select($select_statement);
		# Check to make sure 1 row was returned
	if (scalar @selected_rows == 0) {
		return 0;
	}
	elsif (scalar @selected_rows > 1) {
		notify($ERRORS{'WARNING'}, 0, "" . scalar @selected_rows . " rows were returned from database select");
		return 0;
	}
	my $flavor = $selected_rows[0]{flavor};

	if (defined($flavor) && $flavor ne "") {
		notify($ERRORS{'OK'}, 0, "Using flavor from database");
		return $flavor;
	} else {
		notify($ERRORS{'OK'}, 0, "Flavor from database is NULL, using default flavor from openstack configuration file");
		return $os_default_flavor;
	}
} ## end sub get_image_size

#/////////////////////////////////////////////////////////////////////////////

=head2  getimagesize

 Parameters  : imagename
 Returns : 0 failure or size of image
 Description : in size of Kilobytes

=cut

sub get_image_size {
	my $self = shift;
	if (ref($self) !~ /open/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return 0;
	}

	notify($ERRORS{'OK'}, 0, "No image size information in Openstack");

	return;
} ## end sub get_image_size

#/////////////////////////////////////////////////////////////////////////////

=head2 _set_openstack_user_conf

 Parameters  : None
 Returns : 1(success) or 0(failure)
 Description : load environment profile and set global environemnt variables

example: openstack.conf
"os_tenant_name" => "admin",
"os_username" => "admin",
"os_password" => "adminpassword",
"os_auth_url" => "http://openstack_nova_url:5000/v2.0/",

=cut

sub _set_openstack_user_conf {

	my $self = shift;
	notify($ERRORS{'OK'}, 0, "********* Set OpenStack User Configuration******************");
	my $computer_shortname   = $self->data->get_computer_short_name;
	notify($ERRORS{'OK'}, 0,  "computer_shortname: $computer_shortname");
	# User's environment file
	my $user_config_file = '/etc/vcl/openstack/openstack.conf';
	notify($ERRORS{'OK'}, 0,  "loading $user_config_file");
	my %config = do($user_config_file);
	if (!%config) {
		notify($ERRORS{'CRITICAL'},0, "failure to process $user_config_file");
		return 0;
	}
	$self->{config} = \%config;
	my $os_auth_url = $self->{config}->{os_auth_url};
	my $os_tenant_name = $self->{config}->{os_tenant_name};
	my $os_username = $self->{config}->{os_username};
	my $os_password = $self->{config}->{os_password};
	my $os_default_flavor = $self->{config}->{os_default_flavor};

	my $compute = Net::OpenStack::Compute->new(
		auth_url	=> $os_auth_url,
		user		=> $os_username,
		password	=> $os_password,
		project_id	=> $os_tenant_name,
	);

	$self->{compute} = $compute;

	return 1;
}# _set_openstack_user_conf close

#/////////////////////////////////////////////////////////////////////////////

=head2 _match_image_name

 Parameters  : None
 Returns : image_name of Openstack
 Description : match VCL image name with Openstack image name and set the image_name

=cut

sub _match_image_name {

	# Set image name
	my $vcl_image_name = shift;

	my $select_statement = "
	SELECT
	openstackImageNameMap.openstackimagename as openstack_name,
	openstackImageNameMap.vclimagename as vcl_name
	FROM
	openstackImageNameMap
	WHERE
	openstackImageNameMap.vclimagename = '$vcl_image_name'
	";

	notify($ERRORS{'OK'}, 0, "$select_statement");
	# Call the database select subroutine
	# This will return an array of one or more rows based on the select statement
	my @selected_rows = database_select($select_statement);
	# Check to make sure 1 row was returned
	if (scalar @selected_rows == 0) {
		return 1;
	}
	elsif (scalar @selected_rows > 1) {
		notify($ERRORS{'WARNING'}, 0, "" . scalar @selected_rows . " rows were returned from database select");
		return 0;
	}
	my $openstack_image_name = $selected_rows[0]{openstack_name};
	my $vcl_imagename  = $selected_rows[0]{vcl_name};

	notify($ERRORS{'OK'}, 0, "new image name (openstack_image_name) =$openstack_image_name");
	notify($ERRORS{'OK'}, 0, "new image name (vcl_image_name) =$vcl_imagename");

	return $openstack_image_name;

}# _match_image_name close

sub _terminate_instances {
	my $self = shift;

	my $computer_shortname  = $self->data->get_computer_short_name;
	my $instance_private_ip = $self->data->get_computer_private_ip_address();
	my $instance_id = $self->_get_instance_id;
	$self->_delete_computer_mapping;

	if ($instance_id) {
		notify($ERRORS{'OK'}, 0, "Terminate the existing instance");
		try {
			$self->{compute}->delete_server($instance_id);
			notify($ERRORS{'OK'}, 0, "Deleted instance $instance_id");
		}
		catch {
			notify($ERRORS{'WARNING'}, 0, "Failed to delete instance $instance_id: $_");
		};
	}
	else {
		notify($ERRORS{'OK'}, 0, "No instance found for $computer_shortname");
	}
	
	if ($instance_private_ip) {
		# Remove the computer and IP address from /etc/hosts to avoid duplicates -- Curtis
		# Wonder if we just need to delete the computer name not the IP too...
		my $sedoutput_computer_shortname = `sed -i "/.*\\b$computer_shortname\$/d" /etc/hosts`;
		notify($ERRORS{'DEBUG'}, 0, "sed output to delete $computer_shortname from hosts file: $sedoutput_computer_shortname");
		my $sedoutput_instance_private_ip = `sed -i "/^$instance_private_ip/d" /etc/hosts`;
		notify($ERRORS{'DEBUG'}, 0, "sed output to delete $instance_private_ip from hosts file: $sedoutput_instance_private_ip");
		# done
	}

	return 1;
}

sub _run_instances {
	my $self = shift;

	my $key_name = 'vclkey';
	my $image_full_name = $self->data->get_image_name;
	my $computer_shortname  = $self->data->get_computer_short_name;

	my $image_name = _match_image_name($image_full_name);
	if ($image_name  =~ m/(\w{8}-\w{4}-\w{4}-\w{4}-\w{12})/g) {
		notify($ERRORS{'OK'}, 0, "Acquire the Image ID: $image_name");
	}
	else {
		notify($ERRORS{'DEBUG'}, 0, "Fail to acquire the Image ID: $image_name");
		return 0;
	}

	my $flavor_type = $self->_get_image_flavor($image_name);
	notify($ERRORS{'DEBUG'}, 0, "flavor is: $flavor_type");
	my $instance;

	try {
		$instance = $self->{compute}->create_server({ name => $computer_shortname, flavorRef => $flavor_type, imageRef => $image_name });
	}
	catch {
		notify($ERRORS{'WARNING'}, 0, "Failed to run instance: $_");
	};

	if (!$instance->{id}) {
		return 0;
	}

	notify($ERRORS{'OK'}, 0, "Instance $instance->{id} created successfully");
	my $insert_success = $self->_insert_instance_id($instance->{id});

	if (!$insert_success) {
		return 0;
	}

	return $instance;
}

sub _update_private_ip {
	my $self = shift;

	my $instance_id = shift;
	my $main_loop = 60;
	my $describe_instance_output;
	my $computer_shortname  = $self->data->get_computer_short_name;

	while($main_loop > 0) {
		my $instance = $self->{compute}->get_server($instance_id);
		if (!$instance) {
			notify($ERRORS{'WARNING'}, 0, "Couldn't find instance");
			return 0;
		}

		my $addresses = $instance->{addresses};
		my @keys = keys %$addresses;
		if (scalar @keys > 0) {
			my $private_ip = $addresses->{$keys[0]}[0]->{addr};
			notify($ERRORS{'OK'}, 0, "The instance private IP on Computer $computer_shortname: $private_ip");

			if ($private_ip ne "") {
				notify($ERRORS{'OK'}, 0, "Removing old hosts entry");
				my $sedoutput = `sed -i "/.*\\b$computer_shortname\$/d" /etc/hosts`;
				notify($ERRORS{'DEBUG'}, 0, $sedoutput);
				`echo -e "$private_ip\t$computer_shortname" >> /etc/hosts`;
				my $new_private_ip = $self->data->set_computer_private_ip_address($private_ip);
				if (!$new_private_ip) {
					notify($ERRORS{'WARNING'}, 0, "The $private_ip on Computer $computer_shortname is NOT updated");
					return 0;
				}
				return 1;
			}
		}

		notify($ERRORS{'OK'}, 0, "Sleeping while waiting for instance to obtain IP address");
		sleep 20;
		$main_loop--;
	}

	notify($ERRORS{'WARNING'}, 0, "Timed out while waiting for instance to obtain IP address");
	return 0;
}
#/////////////////////////////////////////////////////////////////////////////

1;
__END__
