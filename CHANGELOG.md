apache_tomcat CHANGELOG
=======================
This file is used to list changes made in each version of the apache_tomcat cookbook.

0.3.1 - 2016-05-09
------
* fix unterminated string in setenv.sh when enabling debug_port

0.3.0 - 2016-04-02
------
* add shutdown_command attribute to protect against unauthorized shutdown
* default to sysvinit (can be overridden via poise-service settings)
* fix sysvinit script

0.2.0 - 2016-02-07
-------
Initial release of the apache_tomcat cookbook.
