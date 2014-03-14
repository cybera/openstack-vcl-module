# OpenStack VCL Module

This is an updated version of the module that can be found in the [Apache VCL JIRA system](https://issues.apache.org/jira/browse/VCL-590) by Young Oh. It may not work with all OpenStack + VCL systems. This documentation is currently very incomplete and installation may fail.

## Requirements

    $ cpan
    > force install Net::OpenStack::Compute
    > install Try::Tiny

NOTE: This module assumes you are using OpenStack and NAT and that your management node is in the same tenant as the entire system.

## Installation

(In progress)

    $ mysql vcl < openstack.sql
    $ cp openstack.pm <vcl_install_path>/lib/VCL/Module/Provisioning

An existing OpenStack image will need to be inserted manually into the database. Additional entries will also need to be inserted into the OS table depending on which operating systems you use.
