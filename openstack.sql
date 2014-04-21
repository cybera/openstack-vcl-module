CREATE TABLE IF NOT EXISTS `openstackComputerMap` (
  `instanceid` varchar(50) NOT NULL,
  `computerid` smallint(5) unsigned,
  PRIMARY KEY (`instanceid`),
  UNIQUE KEY (`computerid`)
) ENGINE=InnoDB DEFAULT CHARSET=latin1;

CREATE TABLE IF NOT EXISTS openstackImageNameMap (
  openstackimagename varchar(50) NOT NULL DEFAULT '',
  vclimagename varchar(50) NOT NULL DEFAULT '',
  flavor tinyint(4) DEFAULT NULL,
  PRIMARY KEY (openstackimagename,vclimagename)
) ENGINE=InnoDB DEFAULT CHARSET=latin1;

ALTER TABLE `openstackComputerMap`
  ADD CONSTRAINT `openstackComputerMap_ibfk_1` FOREIGN KEY (`computerid`) REFERENCES `computer` (`id`) ON DELETE SET NULL ON UPDATE CASCADE;

INSERT INTO module (id, name, prettyname, description, perlpackage)
  VALUES (28, 'provisioning_openstack', 'OpenStack', '', 'VCL::Module::Provisioning::openstack');

INSERT INTO provisioning (id, name, prettyname, moduleid)
  VALUES (NULL, 'openstack', 'OpenStack Provisioning', '28');

INSERT INTO OSinstalltype (id, name)
  VALUES (6, 'openstack');

INSERT INTO provisioningOSinstalltype (provisioningid, OSinstalltypeid)
  VALUES ('11', '6');

-- Change based on your own OS requirements
INSERT INTO OS (id, name, prettyname, type, installtype, sourcepath, moduleid)
  VALUES (45, "rhel6openstack", "CentOS 6 OpenStack", "linux", "openstack", "centos6", 5);
