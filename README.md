ami2emi
=======

AMI-to-EMI Conversion Script.

Invoke it as such:

ami-multi-launcher.sh ami-xxxxxxxx ami-yyyyyyyy ami-zzzzzzzz

It kinda works, but with lots of caveats re: AMIs that will work:

* Assumes an Ubuntu image.
* Assumes a pbgrub kernel.
* Assumes an instance-backed image.

It's also very hacky shell script. The right thing to do, long term, will be to rewrite this as a Eutester script. 

Patches welcome.
