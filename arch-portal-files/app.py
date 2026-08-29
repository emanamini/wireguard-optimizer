from flask import Flask, render_template, request, jsonify
import subprocess
import re
import time
import datetime # Added for MAC logging

app = Flask(__name__)

# --- DYNAMIC FUTURE-PROOFING ---
def fetch_lan_prefix():
    """Dynamically finds the first 3 octets of the router's LAN IP."""
    try:
        # Try the specific 'lan' interface first
        result = subprocess.run(['ip', '-4', '-o', 'addr', 'show', 'dev', 'lan'], capture_output=True, text=True)
        match = re.search(r'inet\s+(\d+\.\d+\.\d+)\.\d+/', result.stdout)
        if match:
            return match.group(1)
    except:
        pass
        
    try:
        # Fallback to any RFC1918 private network space (10.x, 172.16-31.x, 192.168.x)
        result = subprocess.run(['ip', '-4', '-o', 'addr', 'show'], capture_output=True, text=True)
        match = re.search(r'inet\s+(10\.\d+\.\d+|172\.(?:1[6-9]|2[0-9]|3[0-1])\.\d+|192\.168\.\d+)\.\d+/', result.stdout)
        if match:
            return match.group(1)
    except:
        pass
        
    # Ultimate fallback just in case
    return "172.22.0"

# Set the prefix dynamically on startup
LAN_PREFIX = fetch_lan_prefix()
print(f"System initialized. Dynamic LAN Prefix locked to: {LAN_PREFIX}.X")

# --- RATE LIMITING & LOGGING ---
last_toggle_times = {}
TOGGLE_COOLDOWN_SECONDS = 3.0
LOG_FILE = "/opt/arch-portal/devices.log" # For MAC registration

def get_vpn_state(octet):
    try:
        octet_str = str(octet)
        result = subprocess.run(['ip', 'rule', 'list'], capture_output=True, text=True)
        search_string = f"{LAN_PREFIX}.{octet_str} "
        if search_string in result.stdout:
            return False 
        return True 
    except Exception as e:
        print(f"Error checking ip rule: {e}")
        return True

def get_device_name(octet):
    target_ip = f"{LAN_PREFIX}.{octet}"
    actual_mac = None

    # Step 1: Discover the REAL physical MAC currently using this IP via ARP cache
    try:
        arp_result = subprocess.run(['ip', 'neigh', 'show', target_ip], capture_output=True, text=True)
        match = re.search(r'([0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){5})', arp_result.stdout)
        if match:
            actual_mac = match.group(1).upper()
    except:
        pass

    # Step 2: Search dnsmasq.conf for the NAME tied to that specific MAC address
    if actual_mac:
        try:
            with open('/etc/dnsmasq.conf', 'r') as f:
                for line in f:
                    if 'dhcp-host=' in line and actual_mac.lower() in line.lower():
                        parts = line.strip().split('dhcp-host=')[-1].split(',')
                        
                        for part in parts:
                            part = part.strip()
                            if ':' not in part and '.' not in part and part != '':
                                return part
        except Exception as e:
            pass
            
    return "Unknown Device"

def get_mac_address(octet):
    target_ip = f"{LAN_PREFIX}.{octet}"
    mac = None
    
    # 1. Try ARP cache first
    try:
        arp_result = subprocess.run(['ip', 'neigh', 'show', target_ip], capture_output=True, text=True)
        match = re.search(r'([0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){5})', arp_result.stdout)
        if match:
            mac = match.group(1).upper()
    except:
        pass
        
    # 2. Fallback: Check dnsmasq.conf
    if not mac:
        try:
            with open('/etc/dnsmasq.conf', 'r') as f:
                for line in f:
                    if 'dhcp-host=' in line and target_ip in line:
                        parts = line.strip().split('dhcp-host=')[-1].split(',')
                        for part in parts:
                            if ':' in part:
                                match = re.search(r'([0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){5})', part)
                                if match:
                                    mac = match.group(1).upper()
                                    break
                        if mac:
                            break
        except:
            pass
            
    return mac if mac else "UNKNOWN MAC"

def is_trusted_requester(octet):
    """
    SECURITY CHECK: Validates if the IP is in the trusted range AND 
    if the physical MAC address matches the registered MAC in dnsmasq.
    """
    if not octet.isdigit() or int(octet) < 100 or int(octet) > 254:
        return False
        
    target_ip = f"{LAN_PREFIX}.{octet}"
    
    # 1. Get the actual physical MAC currently using this IP
    actual_mac = None
    try:
        arp_result = subprocess.run(['ip', 'neigh', 'show', target_ip], capture_output=True, text=True)
        match = re.search(r'([0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){5})', arp_result.stdout)
        if match:
            actual_mac = match.group(1).upper()
    except:
        pass
        
    if not actual_mac:
        return False # IP spoofed or device not truly on network
        
    # 2. Verify that this exact MAC is authorized for this IP in dnsmasq
    try:
        with open('/etc/dnsmasq.conf', 'r') as f:
            for line in f:
                if 'dhcp-host=' in line and target_ip in line:
                    if actual_mac.lower() in line.lower():
                        return True # Identity verified
    except:
        pass
        
    return False # MAC does not match registered IP -> Spoofing detected

@app.route('/')
def index():
    client_ip = request.headers.get('X-Forwarded-For', request.remote_addr)
    if not client_ip or '.' not in client_ip:
        client_ip = f"{LAN_PREFIX}.0"
        
    octet = client_ip.split('.')[-1]
    vpn_enabled = get_vpn_state(octet)
    device_name = get_device_name(octet)
    mac_address = get_mac_address(octet)
    is_trusted = is_trusted_requester(octet)
    
    return render_template('index.html', ip_octet=octet, vpn_enabled=vpn_enabled, 
                           device_name=device_name, mac_address=mac_address, is_trusted=is_trusted)

@app.route('/api/status')
def status():
    octet = request.args.get('octet')
    if not octet or not str(octet).isdigit():
        return jsonify({"error": "Invalid octet"}), 400
    
    return jsonify({
        "vpn_enabled": get_vpn_state(octet),
        "device_name": get_device_name(octet),
        "mac_address": get_mac_address(octet),
        "ip_octet": octet
    })

@app.route('/api/poll')
def poll():
    octet = request.args.get('octet')
    if not octet or not str(octet).isdigit():
        return jsonify({"error": "Invalid"}), 400
    return jsonify({"vpn_enabled": get_vpn_state(octet)})

@app.route('/api/toggle', methods=['POST'])
def toggle():
    client_ip = request.headers.get('X-Forwarded-For', request.remote_addr)
    if not client_ip or '.' not in client_ip:
        client_ip = f"{LAN_PREFIX}.0"
        
    requester_octet = client_ip.split('.')[-1]
    
    # --- STRICT IDENTITY VERIFICATION ---
    if not is_trusted_requester(requester_octet):
        print(f"SECURITY BLOCK: Untrusted/Spoofed IP (.{requester_octet}) tried to toggle routing.")
        return jsonify({
            "success": False, 
            "error": "Unauthorized. Identity verification failed.",
            "vpn_enabled": True
        }), 403 

    data = request.get_json(force=True) 
    octet = str(data.get('octet')) 
    desired_state = data.get('state') 
    
    if not octet.isdigit():
        return jsonify({"error": "Invalid octet"}), 400

    current_time = time.time()
    last_time = last_toggle_times.get(octet, 0)
    
    if (current_time - last_time) < TOGGLE_COOLDOWN_SECONDS:
        return jsonify({
            "success": False, 
            "error": "Too many requests. Please wait 3 seconds before toggling again.",
            "vpn_enabled": get_vpn_state(octet)
        }), 429 

    last_toggle_times[octet] = current_time
        
    current_state = get_vpn_state(octet)
    
    if current_state != desired_state:
        try:
            cmd = ['sudo', '/opt/router/scripts/toggle-route', '--octet', octet]
            result = subprocess.run(cmd, capture_output=True, text=True)
            
            if result.returncode != 0:
                error_msg = result.stderr.strip() or result.stdout.strip() or "Unknown script error"
                return jsonify({"success": False, "error": error_msg, "vpn_enabled": current_state}), 500
                
        except Exception as e:
            return jsonify({"success": False, "error": str(e), "vpn_enabled": current_state}), 500
            
    final_state = get_vpn_state(octet)
    return jsonify({"success": True, "vpn_enabled": final_state})

@app.route('/api/submit-mac', methods=['POST'])
def submit_mac():
    try:
        data = request.get_json(force=True)
        custom_name = data.get('name', '').strip()
        target_octet = data.get('target_octet') # Supplied ONLY if registering via advanced settings
        
        client_ip = request.headers.get('X-Forwarded-For', request.remote_addr)
        if not client_ip or '.' not in client_ip:
            client_ip = f"{LAN_PREFIX}.0"
        
        requester_octet = client_ip.split('.')[-1]
        
        # If they are trying to register ANOTHER device via advanced settings...
        if target_octet and str(target_octet).isdigit():
            # STRICT SECURITY BOUNDARY: Block untrusted users from fetching/registering other devices
            if not is_trusted_requester(requester_octet):
                return jsonify({"success": False, "error": "Unauthorized. Only trusted devices can register targets."}), 403
            
            log_ip = f"{LAN_PREFIX}.{target_octet}"
            log_mac = get_mac_address(target_octet)
            if not custom_name:
                custom_name = get_device_name(target_octet)
                
        # If they are registering themselves...
        else:
            log_ip = client_ip
            log_mac = get_mac_address(requester_octet)
            if not custom_name:
                custom_name = get_device_name(requester_octet)

        timestamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        log_entry = f"[{timestamp}] IP: {log_ip} | MAC: {log_mac} | Name: {custom_name}\n"
        
        with open(LOG_FILE, "a") as f:
            f.write(log_entry)
            
        return jsonify({"success": True, "message": "Device MAC logged successfully!"})
    except Exception as e:
        return jsonify({"success": False, "error": str(e)}), 500

import os

def read_state_file(filepath):
    """Safely parses bash variable files into a Python dictionary."""
    data = {}
    if os.path.exists(filepath):
        try:
            with open(filepath, 'r') as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith('#'): continue
                    if '=' in line:
                        k, v = line.split('=', 1)
                        data[k.strip()] = v.strip().strip('"\'')
        except Exception:
            pass
    return data

@app.route('/api/optimizer-status')
def optimizer_status():
    """Reads real-time state files dynamically based on config."""
    conf = read_state_file('/etc/wg-optimizer.conf')
    
    # Changed default from 'tun0 tun1' to 'tun0' to match your setup
    interfaces_str = conf.get('HEALTH_MONITOR_INTERFACES', 'tun0')
    interfaces = interfaces_str.split()
    
    global_state = read_state_file('/opt/router/wg-optimizer/wg-health-monitor.state')
    
    interface_states = {}
    for iface in interfaces:
        iface_state = read_state_file(f'/opt/router/wg-optimizer/state/{iface}-health.state')
        
        current_state = iface_state.get('STATE', 'unknown')
        if current_state == 'unknown' and global_state.get('STATUS') == 'testing':
            current_state = 'pending'
            
        interface_states[iface] = {
            "state": current_state,
            "message": iface_state.get('MESSAGE', 'Waiting...')
        }
        
    return jsonify({
        "global": {
            "status": global_state.get('STATUS', 'unknown'),
            "message": global_state.get('MESSAGE', '')
        },
        "interfaces": interface_states
    })

@app.route('/api/optimize-vpn', methods=['POST'])
def optimize_vpn():
    client_ip = request.headers.get('X-Forwarded-For', request.remote_addr)
    if not client_ip or '.' not in client_ip:
        client_ip = f"{LAN_PREFIX}.0"
        
    requester_octet = client_ip.split('.')[-1]
    
    # STRICT SECURITY BOUNDARY
    if not is_trusted_requester(requester_octet):
        print(f"SECURITY BLOCK: Untrusted/Spoofed IP (.{requester_octet}) tried to run VPN optimizer.")
        return jsonify({"success": False, "error": "Unauthorized"}), 403

    try:
        # Execute the health-monitor request wrapper with sudo
        cmd = ['sudo', '/opt/router/wg-optimizer/wg-health-monitor-request.sh']
        result = subprocess.run(cmd, capture_output=True, text=True)

        # Extract only non-empty lines and inspect the final protocol line
        lines = [line.strip() for line in result.stdout.strip().splitlines() if line.strip()]
        last_line = lines[-1] if lines else ""

        if not last_line:
            error_msg = result.stderr.strip() or "No response from health monitor."
            return jsonify({
                "success": False,
                "error": error_msg
            }), 500

        parts = last_line.split('|', 1)
        status = parts[0]
        payload = parts[1] if len(parts) > 1 else ""

        if status == "SUCCESS":
            return jsonify({
                "success": True,
                "status": "SUCCESS",
                "message": "VPN health check completed successfully.",
                "timestamp": payload
            })

        if status == "FAILURE":
            return jsonify({
                "success": False,
                "status": "FAILURE",
                "message": "VPN health check failed.",
                "timestamp": payload
            }), 500

        if status == "COOLDOWN":
            remaining = int(payload) if payload.isdigit() else 0
            return jsonify({
                "success": False,
                "status": "COOLDOWN",
                "message": "VPN health check is on cooldown.",
                "remaining": remaining
            }), 429

        if status == "BUSY":
            return jsonify({
                "success": False,
                "status": "BUSY",
                "message": payload or "A VPN health check request is already being processed."
            }), 409

        return jsonify({
            "success": False,
            "status": "UNKNOWN",
            "error": "Unknown response from health monitor.",
            "raw": last_line
        }), 500

    except Exception as e:
        return jsonify({
            "success": False,
            "error": str(e)
        }), 500

if __name__ == '__main__':
    app.run(host='127.0.0.1', port=8080, debug=False, use_reloader=False)