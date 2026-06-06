package com.threadmark.remotedesktop

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Looper
import android.net.wifi.WifiManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

class LocalHostDiscovery(
    context: Context,
    private val cloudKit: CloudKitClient,
    private val scope: CoroutineScope,
    private val onHostsChanged: (List<LocalHostAdvertisement>) -> Unit,
    private val onCloudKitError: (Throwable) -> Unit,
) {
    private val appContext = context.applicationContext
    private val nsdManager = appContext.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val wifiManager = appContext.getSystemService(Context.WIFI_SERVICE) as WifiManager?
    private val localHosts = linkedMapOf<String, LocalHostAdvertisement>()
    private val cloudHosts = linkedMapOf<String, LocalHostAdvertisement>()
    private var discoveryListener: NsdManager.DiscoveryListener? = null
    private var cloudJob: Job? = null
    private var multicastLock: WifiManager.MulticastLock? = null

    fun start() {
        stop(notify = false)
        startNsd()
        cloudJob = scope.launch {
            while (isActive) {
                try {
                    val advertisements = CloudKitSignalingClient.fetchAvailableHostAdvertisements(cloudKit)
                    cloudHosts.clear()
                    advertisements.forEach { cloudHosts[it.id] = it }
                    sync()
                } catch (error: Throwable) {
                    emitCloudKitError(error)
                }
                delay(3_000L)
            }
        }
    }

    fun stop() {
        stop(notify = true)
    }

    private fun stop(notify: Boolean) {
        discoveryListener?.let {
            runCatching { nsdManager.stopServiceDiscovery(it) }
        }
        discoveryListener = null
        multicastLock?.let {
            if (it.isHeld) it.release()
        }
        multicastLock = null
        cloudJob?.cancel()
        cloudJob = null
        localHosts.clear()
        cloudHosts.clear()
        if (notify) sync()
    }

    private fun startNsd() {
        multicastLock = wifiManager
            ?.createMulticastLock("RemoteDesktopDiscovery")
            ?.apply {
                setReferenceCounted(false)
                acquire()
            }
        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(regType: String) = Unit
            override fun onDiscoveryStopped(serviceType: String) = Unit
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                runCatching { nsdManager.stopServiceDiscovery(this) }
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
                runCatching { nsdManager.stopServiceDiscovery(this) }
            }

            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                LocalHostAdvertisement.parse(serviceInfo.serviceName)?.let {
                    scope.launch(Dispatchers.Main) {
                        localHosts[serviceInfo.serviceName] = it
                        sync()
                    }
                }
            }

            override fun onServiceLost(serviceInfo: NsdServiceInfo) {
                scope.launch(Dispatchers.Main) {
                    localHosts.remove(serviceInfo.serviceName)
                    sync()
                }
            }
        }
        discoveryListener = listener
        nsdManager.discoverServices(
            LocalHostAdvertisement.SERVICE_TYPE,
            NsdManager.PROTOCOL_DNS_SD,
            listener,
        )
    }

    private fun sync() {
        val hostsByCode = linkedMapOf<String, LocalHostAdvertisement>()
        localHosts.values.forEach { hostsByCode[it.code] = it }
        cloudHosts.values.forEach { hostsByCode.putIfAbsent(it.code, it) }
        val sorted = hostsByCode.values.sortedWith(
            compareBy<LocalHostAdvertisement> { it.hostname.lowercase() }
                .thenBy { it.code }
        )
        emitHostsChanged(sorted)
    }

    private fun emitHostsChanged(hosts: List<LocalHostAdvertisement>) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            onHostsChanged(hosts)
        } else {
            scope.launch(Dispatchers.Main) {
                onHostsChanged(hosts)
            }
        }
    }

    private fun emitCloudKitError(error: Throwable) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            onCloudKitError(error)
        } else {
            scope.launch(Dispatchers.Main) {
                onCloudKitError(error)
            }
        }
    }
}
