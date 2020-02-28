#!/bin/bash

name=$1

if [ -z $1 ] ; then
  echo "Usage: $0 [name]"
  echo "Stop running servers with name [name]."
  exit 1
fi

echo "Stopping running servers under name '$name'."

for s in `cat SERVER_LIST` ; do
    if [ $HOSTNAME == $s ] ; then
        echo Self: $s
    else
        echo $s
        screens=`ssh $s 'screen -ls | grep '$name' | cut -f 2'`
        for x in $screens ; do
            echo "Stopping $x"
            ssh $s 'screen -X -S '$x' quit'
        done
    fi
done
