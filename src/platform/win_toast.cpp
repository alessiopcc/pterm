/*
 * Native Windows toast notifications via WinRT.
 *
 * Replaces the previous PowerShell-based toast (which spawned powershell.exe
 * per call and flashed a console window on a windowed-subsystem app).
 *
 * Approach:
 *   - SetCurrentProcessExplicitAppUserModelID binds the running process to
 *     "dev.pterm.PTerm".
 *   - A Start-menu .lnk shortcut with PKEY_AppUserModel_ID set is created on
 *     first run so Windows accepts CreateToastNotifierWithId for that AUMID.
 *   - WinRT entry points (RoActivateInstance, RoGetActivationFactory,
 *     WindowsCreateStringReference) are loaded from combase.dll at runtime —
 *     Zig's bundled MinGW import libs don't ship runtimeobject.lib, and the
 *     SDK's WinRT C++ headers depend on MSVC-only attributes. Instead we
 *     declare the few interfaces we use as raw COM vtables.
 *
 * The interfaces we manually declare:
 *   IInspectable                       (AF86E2E0-B12D-4C6A-9C5A-D7AA65101E90)
 *   IXmlDocumentIO                     (6CD0E74E-EE65-4489-9EBF-CA43E87BA637)
 *   IXmlDocument                       — passed by pointer only (opaque)
 *   IToastNotificationManagerStatics   (50AC103F-D235-4598-BBEF-98FE4D1A3AD4)
 *   IToastNotifier                     (75927B93-03F3-41EC-91D3-6E5BAC1B38E7)
 *   IToastNotificationFactory          (04124B20-82C6-4229-B109-FD9ED4662B53)
 *   IToastNotification                 — passed by pointer only (opaque)
 *
 * Method orders are fixed by the WinRT contract; do not reorder.
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <objbase.h>
#include <shobjidl.h>
#include <shlobj.h>
#include <propkey.h>
#include <propvarutil.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>

extern "C" {
#include "win_toast.h"
}

/* =========================================================================
 * WinRT type stubs and entry points (resolved at runtime from combase.dll)
 * ========================================================================= */

typedef struct HSTRING__* HSTRING;
typedef struct HSTRING_HEADER_ {
    union { void *Reserved1; char Reserved2[24]; } Reserved;
} HSTRING_HEADER_;

typedef HRESULT (WINAPI *PFN_RoActivateInstance)(HSTRING, struct IInspectable_ **);
typedef HRESULT (WINAPI *PFN_RoGetActivationFactory)(HSTRING, REFIID, void **);
typedef HRESULT (WINAPI *PFN_WindowsCreateStringReference)(PCWSTR, UINT32, HSTRING_HEADER_ *, HSTRING *);

static PFN_RoActivateInstance           pfn_RoActivateInstance           = NULL;
static PFN_RoGetActivationFactory       pfn_RoGetActivationFactory       = NULL;
static PFN_WindowsCreateStringReference pfn_WindowsCreateStringReference = NULL;
static int g_combase_loaded = 0; /* 0=untried, 1=ok, -1=failed */

static bool combase_load(void) {
    if (g_combase_loaded == 1) return true;
    if (g_combase_loaded == -1) return false;
    HMODULE h = LoadLibraryW(L"combase.dll");
    if (!h) { g_combase_loaded = -1; return false; }
    pfn_RoActivateInstance =
        (PFN_RoActivateInstance)GetProcAddress(h, "RoActivateInstance");
    pfn_RoGetActivationFactory =
        (PFN_RoGetActivationFactory)GetProcAddress(h, "RoGetActivationFactory");
    pfn_WindowsCreateStringReference =
        (PFN_WindowsCreateStringReference)GetProcAddress(h, "WindowsCreateStringReference");
    if (!pfn_RoActivateInstance || !pfn_RoGetActivationFactory || !pfn_WindowsCreateStringReference) {
        g_combase_loaded = -1;
        return false;
    }
    g_combase_loaded = 1;
    return true;
}

/* =========================================================================
 * Manual COM vtable declarations
 *
 * Layout: each interface's vtable inlines its parent interface's methods
 * before adding its own. All methods use STDMETHODCALLTYPE (= __stdcall).
 * ========================================================================= */

typedef int TrustLevel; /* enum BaseTrust=0, PartialTrust, FullTrust */

struct IInspectable_;
struct IXmlDocument_;
struct IXmlDocumentIO_;
struct IToastNotification_;
struct IToastNotifier_;
struct IToastNotificationManagerStatics_;
struct IToastNotificationFactory_;

#define INSPECTABLE_VTBL(SELF)                                                     \
    HRESULT (STDMETHODCALLTYPE *QueryInterface)(SELF *, REFIID, void **);          \
    ULONG   (STDMETHODCALLTYPE *AddRef)(SELF *);                                   \
    ULONG   (STDMETHODCALLTYPE *Release)(SELF *);                                  \
    HRESULT (STDMETHODCALLTYPE *GetIids)(SELF *, ULONG *, IID **);                 \
    HRESULT (STDMETHODCALLTYPE *GetRuntimeClassName)(SELF *, HSTRING *);           \
    HRESULT (STDMETHODCALLTYPE *GetTrustLevel)(SELF *, TrustLevel *);

struct IInspectable_Vtbl { INSPECTABLE_VTBL(IInspectable_) };
struct IInspectable_ { struct IInspectable_Vtbl *lpVtbl; };

/* IXmlDocument and IToastNotification are passed by pointer only — we never
   call interface-specific methods, only Release. Treat them as IInspectable. */
struct IXmlDocument_Vtbl { INSPECTABLE_VTBL(IXmlDocument_) };
struct IXmlDocument_ { struct IXmlDocument_Vtbl *lpVtbl; };

struct IToastNotification_Vtbl { INSPECTABLE_VTBL(IToastNotification_) };
struct IToastNotification_ { struct IToastNotification_Vtbl *lpVtbl; };

struct IXmlDocumentIO_Vtbl {
    INSPECTABLE_VTBL(IXmlDocumentIO_)
    HRESULT (STDMETHODCALLTYPE *LoadXml)(IXmlDocumentIO_ *, HSTRING);
    HRESULT (STDMETHODCALLTYPE *LoadXmlWithSettings)(IXmlDocumentIO_ *, HSTRING, void *);
    HRESULT (STDMETHODCALLTYPE *SaveToFileAsync)(IXmlDocumentIO_ *, void *, void **);
};
struct IXmlDocumentIO_ { struct IXmlDocumentIO_Vtbl *lpVtbl; };

struct IToastNotifier_Vtbl {
    INSPECTABLE_VTBL(IToastNotifier_)
    HRESULT (STDMETHODCALLTYPE *Show)(IToastNotifier_ *, IToastNotification_ *);
    HRESULT (STDMETHODCALLTYPE *Hide)(IToastNotifier_ *, IToastNotification_ *);
    HRESULT (STDMETHODCALLTYPE *get_Setting)(IToastNotifier_ *, int *);
    HRESULT (STDMETHODCALLTYPE *AddToSchedule)(IToastNotifier_ *, void *);
    HRESULT (STDMETHODCALLTYPE *RemoveFromSchedule)(IToastNotifier_ *, void *);
    HRESULT (STDMETHODCALLTYPE *GetScheduledToastNotifications)(IToastNotifier_ *, void **);
};
struct IToastNotifier_ { struct IToastNotifier_Vtbl *lpVtbl; };

struct IToastNotificationManagerStatics_Vtbl {
    INSPECTABLE_VTBL(IToastNotificationManagerStatics_)
    HRESULT (STDMETHODCALLTYPE *CreateToastNotifier)(IToastNotificationManagerStatics_ *, IToastNotifier_ **);
    HRESULT (STDMETHODCALLTYPE *CreateToastNotifierWithId)(IToastNotificationManagerStatics_ *, HSTRING, IToastNotifier_ **);
    HRESULT (STDMETHODCALLTYPE *GetTemplateContent)(IToastNotificationManagerStatics_ *, int, IXmlDocument_ **);
};
struct IToastNotificationManagerStatics_ { struct IToastNotificationManagerStatics_Vtbl *lpVtbl; };

struct IToastNotificationFactory_Vtbl {
    INSPECTABLE_VTBL(IToastNotificationFactory_)
    HRESULT (STDMETHODCALLTYPE *CreateToastNotification)(IToastNotificationFactory_ *, IXmlDocument_ *, IToastNotification_ **);
};
struct IToastNotificationFactory_ { struct IToastNotificationFactory_Vtbl *lpVtbl; };

/* IIDs (verified against Windows SDK 10.0.22621). */
static const IID IID_IXmlDocumentIO_                     = { 0x6CD0E74E, 0xEE65, 0x4489, { 0x9E, 0xBF, 0xCA, 0x43, 0xE8, 0x7B, 0xA6, 0x37 } };
static const IID IID_IXmlDocument_                       = { 0xF7F3A506, 0x1E87, 0x42D6, { 0xBC, 0xFB, 0xB8, 0xC8, 0x09, 0xFA, 0x54, 0x94 } };
static const IID IID_IToastNotificationManagerStatics_   = { 0x50AC103F, 0xD235, 0x4598, { 0xBB, 0xEF, 0x98, 0xFE, 0x4D, 0x1A, 0x3A, 0xD4 } };
static const IID IID_IToastNotificationFactory_          = { 0x04124B20, 0x82C6, 0x4229, { 0xB1, 0x09, 0xFD, 0x9E, 0xD4, 0x66, 0x2B, 0x53 } };

/* WinRT activatable class names. */
static const wchar_t *const RTC_XmlDocument       = L"Windows.Data.Xml.Dom.XmlDocument";
static const wchar_t *const RTC_ToastManager      = L"Windows.UI.Notifications.ToastNotificationManager";
static const wchar_t *const RTC_ToastNotification = L"Windows.UI.Notifications.ToastNotification";

/* =========================================================================
 * Helpers
 * ========================================================================= */

static wchar_t g_aumid[256] = L"";

static int utf8_to_wide(const char *in, wchar_t *out, int out_size) {
    if (!in || !out || out_size <= 0) return -1;
    int n = MultiByteToWideChar(CP_UTF8, 0, in, -1, out, out_size);
    return n > 0 ? 0 : -1;
}

static bool com_init_local(void) {
    HRESULT hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    return hr == S_OK; /* Don't uninit if S_FALSE or RPC_E_CHANGED_MODE */
}

static void com_uninit_local(bool we_initialized) {
    if (we_initialized) CoUninitialize();
}

static int build_shortcut_path(const wchar_t *display, wchar_t *out_path, size_t out_size) {
    PWSTR programs = NULL;
    HRESULT hr = SHGetKnownFolderPath(FOLDERID_Programs, 0, NULL, &programs);
    if (FAILED(hr) || programs == NULL) return -1;
    int n = swprintf_s(out_path, out_size, L"%s\\%s.lnk", programs, display);
    CoTaskMemFree(programs);
    return n > 0 ? 0 : -1;
}

static bool shortcut_matches(const wchar_t *path, const wchar_t *exe_path, const wchar_t *aumid) {
    if (GetFileAttributesW(path) == INVALID_FILE_ATTRIBUTES) return false;

    IShellLinkW *link = NULL;
    HRESULT hr = CoCreateInstance(CLSID_ShellLink, NULL, CLSCTX_INPROC_SERVER,
                                  IID_IShellLinkW, (void **)&link);
    if (FAILED(hr) || !link) return false;

    bool ok = false;
    IPersistFile *pf = NULL;
    if (SUCCEEDED(link->QueryInterface(IID_IPersistFile, (void **)&pf)) && pf) {
        if (SUCCEEDED(pf->Load(path, STGM_READ))) {
            wchar_t existing[MAX_PATH] = L"";
            if (SUCCEEDED(link->GetPath(existing, MAX_PATH, NULL, 0)) &&
                _wcsicmp(existing, exe_path) == 0) {
                IPropertyStore *ps = NULL;
                if (SUCCEEDED(link->QueryInterface(IID_IPropertyStore, (void **)&ps)) && ps) {
                    PROPVARIANT pv;
                    PropVariantInit(&pv);
                    if (SUCCEEDED(ps->GetValue(PKEY_AppUserModel_ID, &pv))) {
                        if (pv.vt == VT_LPWSTR && pv.pwszVal && wcscmp(pv.pwszVal, aumid) == 0) {
                            ok = true;
                        }
                    }
                    PropVariantClear(&pv);
                    ps->Release();
                }
            }
        }
        pf->Release();
    }
    link->Release();
    return ok;
}

static HRESULT create_shortcut(const wchar_t *path, const wchar_t *exe_path, const wchar_t *aumid) {
    IShellLinkW *link = NULL;
    HRESULT hr = CoCreateInstance(CLSID_ShellLink, NULL, CLSCTX_INPROC_SERVER,
                                  IID_IShellLinkW, (void **)&link);
    if (FAILED(hr) || !link) return FAILED(hr) ? hr : E_FAIL;

    hr = link->SetPath(exe_path);
    if (SUCCEEDED(hr)) hr = link->SetIconLocation(exe_path, 0);

    if (SUCCEEDED(hr)) {
        IPropertyStore *ps = NULL;
        hr = link->QueryInterface(IID_IPropertyStore, (void **)&ps);
        if (SUCCEEDED(hr) && ps) {
            PROPVARIANT pv;
            hr = InitPropVariantFromString(aumid, &pv);
            if (SUCCEEDED(hr)) {
                hr = ps->SetValue(PKEY_AppUserModel_ID, pv);
                PropVariantClear(&pv);
            }
            if (SUCCEEDED(hr)) hr = ps->Commit();
            ps->Release();
        }
    }

    if (SUCCEEDED(hr)) {
        IPersistFile *pf = NULL;
        hr = link->QueryInterface(IID_IPersistFile, (void **)&pf);
        if (SUCCEEDED(hr) && pf) {
            hr = pf->Save(path, TRUE);
            pf->Release();
        }
    }

    link->Release();
    return hr;
}

extern "C" int pterm_notify_init(const char *aumid_utf8, const char *display_name_utf8) {
    if (!aumid_utf8 || !display_name_utf8) return -1;

    wchar_t aumid[256], display[256];
    if (utf8_to_wide(aumid_utf8, aumid, 256) != 0) return -2;
    if (utf8_to_wide(display_name_utf8, display, 256) != 0) return -3;

    wcscpy_s(g_aumid, 256, aumid);
    SetCurrentProcessExplicitAppUserModelID(aumid);

    wchar_t exe_path[MAX_PATH];
    if (GetModuleFileNameW(NULL, exe_path, MAX_PATH) == 0) return -4;

    bool we_init = com_init_local();
    wchar_t shortcut_path[MAX_PATH];
    int rc = build_shortcut_path(display, shortcut_path, MAX_PATH);
    HRESULT hr = S_OK;
    if (rc == 0 && !shortcut_matches(shortcut_path, exe_path, aumid)) {
        hr = create_shortcut(shortcut_path, exe_path, aumid);
    }
    com_uninit_local(we_init);
    if (rc != 0) return rc;
    return SUCCEEDED(hr) ? 0 : (int)hr;
}

static void xml_escape(const wchar_t *in, wchar_t *out, int out_size) {
    int o = 0;
    int max = out_size - 1;
    for (int i = 0; in[i] != 0 && o < max; i++) {
        const wchar_t *rep = NULL;
        switch (in[i]) {
            case L'&':  rep = L"&amp;";  break;
            case L'<':  rep = L"&lt;";   break;
            case L'>':  rep = L"&gt;";   break;
            case L'"':  rep = L"&quot;"; break;
            case L'\'': rep = L"&apos;"; break;
            default: break;
        }
        if (rep) {
            int rl = (int)wcslen(rep);
            if (o + rl > max) break;
            for (int k = 0; k < rl; k++) out[o++] = rep[k];
        } else {
            out[o++] = in[i];
        }
    }
    out[o] = 0;
}

static HRESULT show_toast(const wchar_t *xml_text) {
    if (!combase_load()) return E_FAIL;
    if (g_aumid[0] == 0) return E_FAIL;

    HRESULT hr;

    /* Activate XmlDocument and load XML. */
    HSTRING_HEADER_ h_xml_class, h_xml_text, h_mgr_class, h_aumid, h_toast_class;
    HSTRING xml_class = NULL, xml_text_h = NULL, mgr_class = NULL, aumid_h = NULL, toast_class = NULL;

    hr = pfn_WindowsCreateStringReference(RTC_XmlDocument, (UINT32)wcslen(RTC_XmlDocument), &h_xml_class, &xml_class);
    if (FAILED(hr)) return hr;

    IInspectable_ *xml_inspect = NULL;
    hr = pfn_RoActivateInstance(xml_class, &xml_inspect);
    if (FAILED(hr) || !xml_inspect) return FAILED(hr) ? hr : E_FAIL;

    IXmlDocumentIO_ *xml_io = NULL;
    hr = xml_inspect->lpVtbl->QueryInterface(xml_inspect, IID_IXmlDocumentIO_, (void **)&xml_io);
    if (FAILED(hr) || !xml_io) { xml_inspect->lpVtbl->Release(xml_inspect); return FAILED(hr) ? hr : E_FAIL; }

    hr = pfn_WindowsCreateStringReference(xml_text, (UINT32)wcslen(xml_text), &h_xml_text, &xml_text_h);
    if (SUCCEEDED(hr)) hr = xml_io->lpVtbl->LoadXml(xml_io, xml_text_h);
    xml_io->lpVtbl->Release(xml_io);
    if (FAILED(hr)) { xml_inspect->lpVtbl->Release(xml_inspect); return hr; }

    IXmlDocument_ *xml_doc = NULL;
    hr = xml_inspect->lpVtbl->QueryInterface(xml_inspect, IID_IXmlDocument_, (void **)&xml_doc);
    xml_inspect->lpVtbl->Release(xml_inspect);
    if (FAILED(hr) || !xml_doc) return FAILED(hr) ? hr : E_FAIL;

    /* Get manager statics, create notifier for our AUMID. */
    hr = pfn_WindowsCreateStringReference(RTC_ToastManager, (UINT32)wcslen(RTC_ToastManager), &h_mgr_class, &mgr_class);
    if (FAILED(hr)) { xml_doc->lpVtbl->Release(xml_doc); return hr; }

    IToastNotificationManagerStatics_ *mgr = NULL;
    hr = pfn_RoGetActivationFactory(mgr_class, IID_IToastNotificationManagerStatics_, (void **)&mgr);
    if (FAILED(hr) || !mgr) { xml_doc->lpVtbl->Release(xml_doc); return FAILED(hr) ? hr : E_FAIL; }

    hr = pfn_WindowsCreateStringReference(g_aumid, (UINT32)wcslen(g_aumid), &h_aumid, &aumid_h);
    if (FAILED(hr)) { mgr->lpVtbl->Release(mgr); xml_doc->lpVtbl->Release(xml_doc); return hr; }

    IToastNotifier_ *notifier = NULL;
    hr = mgr->lpVtbl->CreateToastNotifierWithId(mgr, aumid_h, &notifier);
    mgr->lpVtbl->Release(mgr);
    if (FAILED(hr) || !notifier) { xml_doc->lpVtbl->Release(xml_doc); return FAILED(hr) ? hr : E_FAIL; }

    /* Build a ToastNotification from the XML. */
    hr = pfn_WindowsCreateStringReference(RTC_ToastNotification, (UINT32)wcslen(RTC_ToastNotification), &h_toast_class, &toast_class);
    if (FAILED(hr)) { notifier->lpVtbl->Release(notifier); xml_doc->lpVtbl->Release(xml_doc); return hr; }

    IToastNotificationFactory_ *toast_factory = NULL;
    hr = pfn_RoGetActivationFactory(toast_class, IID_IToastNotificationFactory_, (void **)&toast_factory);
    if (FAILED(hr) || !toast_factory) {
        notifier->lpVtbl->Release(notifier);
        xml_doc->lpVtbl->Release(xml_doc);
        return FAILED(hr) ? hr : E_FAIL;
    }

    IToastNotification_ *toast = NULL;
    hr = toast_factory->lpVtbl->CreateToastNotification(toast_factory, xml_doc, &toast);
    toast_factory->lpVtbl->Release(toast_factory);
    xml_doc->lpVtbl->Release(xml_doc);
    if (FAILED(hr) || !toast) { notifier->lpVtbl->Release(notifier); return FAILED(hr) ? hr : E_FAIL; }

    hr = notifier->lpVtbl->Show(notifier, toast);

    /* Show keeps its own ref; release ours. */
    toast->lpVtbl->Release(toast);
    notifier->lpVtbl->Release(notifier);
    return hr;
}

extern "C" int pterm_notify_send(const char *title_utf8, const char *body_utf8, int play_sound) {
    if (g_aumid[0] == 0) return -1; /* init() not called yet */
    if (!title_utf8 || !body_utf8) return -2;

    wchar_t title[256], body[1024];
    if (utf8_to_wide(title_utf8, title, 256) != 0) return -3;
    if (utf8_to_wide(body_utf8, body, 1024) != 0) return -4;

    wchar_t title_esc[1024], body_esc[4096];
    xml_escape(title, title_esc, 1024);
    xml_escape(body, body_esc, 4096);

    const wchar_t *audio = play_sound
        ? L"<audio src=\"ms-winsoundevent:Notification.Default\"/>"
        : L"<audio silent=\"true\"/>";

    wchar_t xml[8192];
    int n = swprintf_s(xml, 8192,
        L"<toast duration=\"short\"><visual><binding template=\"ToastGeneric\">"
        L"<text>%s</text><text>%s</text></binding></visual>%s</toast>",
        title_esc, body_esc, audio);
    if (n <= 0) return -5;

    bool we_init = com_init_local();
    HRESULT hr = show_toast(xml);
    com_uninit_local(we_init);
    return SUCCEEDED(hr) ? 0 : (int)hr;
}
