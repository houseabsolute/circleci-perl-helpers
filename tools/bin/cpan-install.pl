use strict;
use warnings;

use FindBin qw( $Bin );
use lib "$Bin/../lib";

use T::CPANInstall;

exit T::CPANInstall->new->run;
