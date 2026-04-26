# No external packages currently. Wildcard kept so adding one
# later is just a matter of dropping a directory under package/.
include $(sort $(wildcard $(BR2_EXTERNAL_LAPEE_PATH)/package/*/*.mk))
