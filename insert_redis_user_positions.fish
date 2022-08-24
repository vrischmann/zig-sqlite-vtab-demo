#!/usr/bin/env fish

function set_user_position
  set -l _id $argv[1]
  set -l _name $argv[2]
  set -l _postal_code $argv[3]

  redis-cli hmset user:$_id name $_name postal_code $_postal_code
end

set_user_position 20 vrischmann 75001
set_user_position 19 angrybird 23320
set_user_position 18 yellowcake 67170
set_user_position 17 limitedbadger 67550
set_user_position 16 gonetothemarket 69001
set_user_position 15 amplifiedteakettle 23320
set_user_position 14 compiledmango 69001
set_user_position 13 delayedbutterstick 57220
