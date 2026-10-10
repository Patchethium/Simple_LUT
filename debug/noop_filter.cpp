// Do-nothing AviUtl2 filter built from the official SDK header, for checking that the host loads
// plugins at all. Every call is appended to C:\Users\Public\aviutl2_noop.log.
#include <windows.h>
#include <d3d11.h>
#include <dwrite.h>
#include <stdint.h>
#include <string.h>
#include "filter2.h"

static void log_line(const char* text) {
	HANDLE file = CreateFileW(L"C:\\Users\\Public\\aviutl2_noop.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
	if (file == INVALID_HANDLE_VALUE) return;
	DWORD written;
	WriteFile(file, text, (DWORD)strlen(text), &written, nullptr);
	WriteFile(file, "\r\n", 2, &written, nullptr);
	CloseHandle(file);
}

static bool proc_video(FILTER_PROC_VIDEO* video) {
	static bool logged = false;
	if (!logged) {
		logged = true;
		log_line("[cpp] proc_video called");
	}
	return true;
}

auto dummy = FILTER_ITEM_TRACK(L"Dummy", 0.0, 0.0, 100.0, 1.0);
void* items[] = { &dummy, nullptr };

FILTER_PLUGIN_TABLE filter_plugin_table = {
	FILTER_PLUGIN_TABLE::FLAG_VIDEO | FILTER_PLUGIN_TABLE::FLAG_FILTER,
	L"Noop filter (C++)",
	L"Debug",
	L"Do-nothing filter for plugin loading tests",
	items,
	proc_video,
	nullptr,
};

BOOL WINAPI DllMain(HINSTANCE, DWORD reason, LPVOID) {
	if (reason == DLL_PROCESS_ATTACH) log_line("[cpp] DllMain: loaded");
	return TRUE;
}

EXTERN_C __declspec(dllexport) bool InitializePlugin(DWORD version) {
	char text[64];
	wsprintfA(text, "[cpp] InitializePlugin(version=%lu)", version);
	log_line(text);
	return true;
}

EXTERN_C __declspec(dllexport) void UninitializePlugin() {
	log_line("[cpp] UninitializePlugin");
}

EXTERN_C __declspec(dllexport) FILTER_PLUGIN_TABLE* GetFilterPluginTable(void) {
	log_line("[cpp] GetFilterPluginTable");
	return &filter_plugin_table;
}
