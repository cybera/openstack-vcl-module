This is an updated version of the module that can be found in the [Apache VCL JIRA system](https://issues.apache.org/jira/browse/VCL-590) by Young-Hyun. It may not work with all OpenStack + VCL systems.

    $ cpan
    > force install Net::OpenStack::Compute
    > install Try::Tiny

NOTE: This module assumes you are using openstack and NAT and that your managment node is in the same tenant as the entire system.
