CREATE TABLE IF NOT EXISTS `openstackComputerMap` (
  `instanceid` varchar(50) NOT NULL,
  `computerid` smallint(5) unsigned,
  PRIMARY KEY (`instanceid`),
  UNIQUE KEY (`computerid`)
) ENGINE=InnoDB DEFAULT CHARSET=latin1;

ALTER TABLE `openstackComputerMap`
  ADD CONSTRAINT `openstackComputerMap_ibfk_1` FOREIGN KEY (`computerid`) REFERENCES `computer` (`id`) ON DELETE SET NULL ON UPDATE CASCADE;
