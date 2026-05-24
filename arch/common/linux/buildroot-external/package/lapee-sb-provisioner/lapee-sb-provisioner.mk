################################################################################
#
# lapee-sb-provisioner
#
################################################################################

LAPEE_SB_PROVISIONER_SITE = $(BR2_EXTERNAL_LAPEE_PATH)/package/lapee-sb-provisioner/src
LAPEE_SB_PROVISIONER_SITE_METHOD = local

define LAPEE_SB_PROVISIONER_BUILD_CMDS
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) \
		-Wall -Wextra -Werror -O2 \
		-o $(@D)/lapee-sb-provisioner \
		$(@D)/lapee-sb-provisioner.c
endef

define LAPEE_SB_PROVISIONER_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/lapee-sb-provisioner \
		$(TARGET_DIR)/usr/sbin/lapee-sb-provisioner
endef

$(eval $(generic-package))
