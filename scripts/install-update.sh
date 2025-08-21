#!/bin/bash
# Pi-Star A/B Partition Switcher with Kernel Management
set -e

switch_to_partition() {
    TARGET_PART="$1"
    
    if [ "$TARGET_PART" = "A" ]; then
        TARGET_DEV="/dev/mmcblk0p2"
        TARGET_KERNEL_DIR="/boot/kernelA"
        CURRENT_KERNEL_DIR="/boot/kernelB"
    elif [ "$TARGET_PART" = "B" ]; then
        TARGET_DEV="/dev/mmcblk0p3"
        TARGET_KERNEL_DIR="/boot/kernelB"
        CURRENT_KERNEL_DIR="/boot/kernelA"
    else
        echo "❌ Invalid partition: $TARGET_PART (use A or B)"
        exit 1
    fi
    
    echo "🔄 Switching to partition $TARGET_PART ($TARGET_DEV)"
    
    # Get current partition for reference
    CURRENT_PART=$(cat /boot/ab_state 2>/dev/null || echo "unknown")
    echo "📊 Current partition: $CURRENT_PART"
    
    # =====================================================
    # VALIDATE TARGET PARTITION
    # =====================================================
    
    echo "🔍 Validating target partition..."
    
    # Check if target partition is mountable
    mkdir -p /tmp/partition-check
    if ! mount "$TARGET_DEV" /tmp/partition-check 2>/dev/null; then
        echo "❌ Cannot mount target partition $TARGET_DEV"
        rmdir /tmp/partition-check 2>/dev/null || true
        exit 1
    fi
    
    # Check for essential files
    if [ ! -f "/tmp/partition-check/etc/pi-star-version" ]; then
        echo "❌ Target partition does not contain valid Pi-Star system"
        umount /tmp/partition-check
        rmdir /tmp/partition-check
        exit 1
    fi
    
    TARGET_VERSION=$(cat /tmp/partition-check/etc/pi-star-version 2>/dev/null || echo "unknown")
    echo "✅ Target partition contains Pi-Star v$TARGET_VERSION"
    
    umount /tmp/partition-check
    rmdir /tmp/partition-check
    
    # =====================================================
    # SWITCH KERNELS (ALPINE+RASPBIAN HYBRID)
    # =====================================================
    
    echo "🚀 Managing kernel switch for hybrid system..."
    
    # Check if target kernel directory exists and has kernels
    if [ -d "$TARGET_KERNEL_DIR" ] && ls "$TARGET_KERNEL_DIR"/kernel*.img >/dev/null 2>&1; then
        echo "📋 Found kernels for partition $TARGET_PART"
        
        # Backup current kernels to current partition's directory if not already there
        if [ "$CURRENT_PART" != "unknown" ] && [ -d "$CURRENT_KERNEL_DIR" ]; then
            echo "💾 Backing up current kernels to $CURRENT_KERNEL_DIR..."
            mkdir -p "$CURRENT_KERNEL_DIR"
            if ls /boot/kernel*.img >/dev/null 2>&1; then
                cp /boot/kernel*.img "$CURRENT_KERNEL_DIR/"
            fi
        fi
        
        # Switch to target kernels
        echo "🔄 Switching to kernels for partition $TARGET_PART..."
        cp "$TARGET_KERNEL_DIR"/kernel*.img /boot/
        echo "✅ Kernels switched"
        
        # Show kernel info
        if [ -f "$TARGET_KERNEL_DIR/kernel8.img" ]; then
            KERNEL_SIZE=$(ls -lh "$TARGET_KERNEL_DIR/kernel8.img" | awk '{print $5}')
            echo "📱 Using kernel8.img ($KERNEL_SIZE)"
        fi
    else
        echo "⚠️  No kernels found for partition $TARGET_PART - keeping current kernels"
        echo "    (This may cause boot issues if partitions have different kernel versions)"
    fi
    
    # =====================================================
    # UPDATE BOOT CONFIGURATION
    # =====================================================
    
    echo "⚙️ Updating boot configuration..."
    
    # Update cmdline.txt to point to new root partition
    if [ "$TARGET_PART" = "A" ]; then
        sed -i 's|root=/dev/mmcblk0p[23]|root=/dev/mmcblk0p2|' /boot/cmdline.txt
        sed -i 's|root=/dev/mmcblk0p[23]|root=/dev/mmcblk0p2|' /boot/cmdline02w.txt 2>/dev/null || true
    else
        sed -i 's|root=/dev/mmcblk0p[23]|root=/dev/mmcblk0p3|' /boot/cmdline.txt
        sed -i 's|root=/dev/mmcblk0p[23]|root=/dev/mmcblk0p3|' /boot/cmdline02w.txt 2>/dev/null || true
    fi
    
    # Update active partition marker
    echo "$TARGET_PART" > /boot/ab_state
    
    # Reset boot attempt counter
    echo "0" > "/boot/boot_attempts_$TARGET_PART"
    
    echo "✅ Boot configuration updated"
    
    # =====================================================
    # SUMMARY
    # =====================================================
    
    echo ""
    echo "📊 Partition Switch Summary:"
    echo "  • From: Partition $CURRENT_PART → Partition $TARGET_PART"
    echo "  • Root: $TARGET_DEV"
    echo "  • Version: $TARGET_VERSION"
    echo "  • Kernel: Switched to partition $TARGET_PART kernels"
    echo "  • Boot attempts: Reset to 0"
    echo ""
    echo "✅ Partition switch complete"
    echo "🔄 Reboot to activate partition $TARGET_PART"
}

# =====================================================
# ROLLBACK FUNCTION
# =====================================================

rollback_failed_boot() {
    echo "🚨 Performing automatic rollback due to boot failure..."
    
    CURRENT_PART=$(cat /boot/ab_state 2>/dev/null || echo "A")
    if [ "$CURRENT_PART" = "A" ]; then
        ROLLBACK_PART="B"
    else
        ROLLBACK_PART="A"
    fi
    
    echo "🔄 Rolling back from partition $CURRENT_PART to $ROLLBACK_PART"
    switch_to_partition "$ROLLBACK_PART"
    
    echo "🛡️ Automatic rollback complete"
    echo "📝 Check /var/log/pistar-updates.log for details"
}

# =====================================================
# MAIN SCRIPT LOGIC
# =====================================================

if [ $# -eq 0 ]; then
    # Show current status
    CURRENT_PART=$(cat /boot/ab_state 2>/dev/null || echo "Unknown")
    CURRENT_VERSION=$(cat /etc/pi-star-version 2>/dev/null || echo "Unknown")
    
    echo "📊 Current A/B Status:"
    echo "  • Active partition: $CURRENT_PART"
    echo "  • Version: $CURRENT_VERSION"
    echo "  • Root device: $(mount | grep ' / ' | cut -d' ' -f1)"
    echo ""
    echo "Usage: $0 <A|B|rollback>"
    echo "  $0 A        - Switch to partition A"
    echo "  $0 B        - Switch to partition B"  
    echo "  $0 rollback - Automatic rollback (used by boot validator)"
    exit 1
fi

case "$1" in
    "A"|"B")
        switch_to_partition "$1"
        ;;
    "rollback")
        rollback_failed_boot
        ;;
    *)
        echo "❌ Invalid option: $1"
        echo "Usage: $0 <A|B|rollback>"
        exit 1
        ;;
esac