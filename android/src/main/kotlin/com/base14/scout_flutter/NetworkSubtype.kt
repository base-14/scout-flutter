package com.base14.scout_flutter

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.telephony.TelephonyCallback
import android.telephony.TelephonyDisplayInfo
import android.telephony.TelephonyManager

object NetworkSubtype {
    @Volatile private var fromDisplayInfo: String = ""
    private var callback: Any? = null

    fun install(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S || callback != null) return
        try {
            val telephony = context.getSystemService(TelephonyManager::class.java) ?: return
            val listener = DisplayInfoCallback()
            telephony.registerTelephonyCallback(context.mainExecutor, listener)
            callback = listener
        } catch (_: Throwable) {
        }
    }

    fun stop(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
        val listener = callback as? TelephonyCallback ?: return
        callback = null
        fromDisplayInfo = ""
        try {
            context.getSystemService(TelephonyManager::class.java)?.unregisterTelephonyCallback(listener)
        } catch (_: Throwable) {
        }
    }

    fun current(context: Context): String = fromDisplayInfo.ifEmpty { fromDataNetworkType(context) }

    private fun fromDataNetworkType(context: Context): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
            context.checkSelfPermission(Manifest.permission.READ_PHONE_STATE) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return ""
        }
        return try {
            val telephony = context.getSystemService(TelephonyManager::class.java)
            if (telephony == null) "" else subtypeOf(telephony.dataNetworkType)
        } catch (_: Throwable) {
            ""
        }
    }

    @androidx.annotation.RequiresApi(Build.VERSION_CODES.S)
    private class DisplayInfoCallback : TelephonyCallback(), TelephonyCallback.DisplayInfoListener {
        override fun onDisplayInfoChanged(telephonyDisplayInfo: TelephonyDisplayInfo) {
            fromDisplayInfo =
                subtypeOf(telephonyDisplayInfo.networkType, telephonyDisplayInfo.overrideNetworkType)
        }
    }

    @Suppress("DEPRECATION")
    @android.annotation.SuppressLint("InlinedApi")
    fun subtypeOf(
        networkType: Int,
        overrideNetworkType: Int = TelephonyDisplayInfo.OVERRIDE_NETWORK_TYPE_NONE,
    ): String {
        val overridden = when (overrideNetworkType) {
            TelephonyDisplayInfo.OVERRIDE_NETWORK_TYPE_LTE_CA,
            TelephonyDisplayInfo.OVERRIDE_NETWORK_TYPE_LTE_ADVANCED_PRO,
            -> "lte_ca"
            TelephonyDisplayInfo.OVERRIDE_NETWORK_TYPE_NR_NSA,
            TelephonyDisplayInfo.OVERRIDE_NETWORK_TYPE_NR_NSA_MMWAVE,
            -> "nrnsa"
            TelephonyDisplayInfo.OVERRIDE_NETWORK_TYPE_NR_ADVANCED -> "nr"
            else -> ""
        }
        if (overridden.isNotEmpty()) return overridden
        return when (networkType) {
            TelephonyManager.NETWORK_TYPE_NR -> "nr"
            TelephonyManager.NETWORK_TYPE_LTE -> "lte"
            TelephonyManager.NETWORK_TYPE_HSPAP -> "hspap"
            TelephonyManager.NETWORK_TYPE_HSPA -> "hspa"
            TelephonyManager.NETWORK_TYPE_HSDPA -> "hsdpa"
            TelephonyManager.NETWORK_TYPE_HSUPA -> "hsupa"
            TelephonyManager.NETWORK_TYPE_UMTS -> "umts"
            TelephonyManager.NETWORK_TYPE_TD_SCDMA -> "td_scdma"
            TelephonyManager.NETWORK_TYPE_EDGE -> "edge"
            TelephonyManager.NETWORK_TYPE_GPRS -> "gprs"
            TelephonyManager.NETWORK_TYPE_GSM -> "gsm"
            TelephonyManager.NETWORK_TYPE_CDMA -> "cdma"
            TelephonyManager.NETWORK_TYPE_1xRTT -> "cdma2000_1xrtt"
            TelephonyManager.NETWORK_TYPE_EVDO_0 -> "evdo_0"
            TelephonyManager.NETWORK_TYPE_EVDO_A -> "evdo_a"
            TelephonyManager.NETWORK_TYPE_EVDO_B -> "evdo_b"
            TelephonyManager.NETWORK_TYPE_EHRPD -> "ehrpd"
            TelephonyManager.NETWORK_TYPE_IDEN -> "iden"
            TelephonyManager.NETWORK_TYPE_IWLAN -> "iwlan"
            else -> ""
        }
    }
}
