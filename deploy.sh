#!/bin/bash

name=$1
base=$2

if [ -z $1 ] || [ -z $2 ] ; then
    echo "Usage: $0 [name] [base]"
    echo "Copies [base]* to each node under ~/run-[name] then"
    echo "executes ~/run-[name]/server.sh under a screen [name]"
    exit 1
fi

echo "Copying $base* to each node under ~/run-$name then executing ./server.sh under screen name '$name'."

for s in `cat SERVER_LIST` ; do
    if [ $HOSTNAME == $s ] ; then
        echo Self: $s
    else
        echo $s
        ssh $s "mkdir -p run-$name"
        scp $base* $s:run-$name/
        b="cd run-$name ; sh ./server.sh ; exec sh"
        ssh $s 'screen -S '$name' -s -/bin/sh -m -d bash -c "'$b'"'
    fi
done
