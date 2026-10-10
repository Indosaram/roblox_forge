// Read-only owned-window registration. No input, title matching or activation.
#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>
#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <filesystem>
#include <iostream>
#include <memory>
#include <mutex>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>
#include "json_line.h"
#include "process_identity.h"

namespace {
using namespace qualityav;
namespace gc = winrt::Windows::Graphics::Capture;
namespace dx = winrt::Windows::Graphics::DirectX;
namespace d3 = winrt::Windows::Graphics::DirectX::Direct3D11;
void Require(bool value, const char* code) { if (!value) throw std::runtime_error(code); }
long long Now() { LARGE_INTEGER value{}; Require(QueryPerformanceCounter(&value), "REGISTRATION_QPC"); return value.QuadPart; }
void Emit(const JsonObject& event) { std::cout << event.Build() << '\n' << std::flush; }
bool Nonce(const std::string& value) {
  return value.size() == 32 && value.find_first_not_of("0123456789abcdef") == std::string::npos;
}
struct Handle {
  HANDLE value = nullptr;
  ~Handle() { if (value && value != INVALID_HANDLE_VALUE) CloseHandle(value); }
};
struct Desktop {
  HDESK value = nullptr;
  // A private desktop is created by this process and must be closed; the calling thread's own
  // desktop (the interactive launch) is owned by the thread and must not be.
  bool owned = false;
  ~Desktop() { if (owned && value) CloseDesktop(value); }
};
struct Candidate { HWND hwnd; ProcessIdentity owner; };
struct Enumeration { HANDLE job; bool failed = false; std::vector<Candidate> rows; };
BOOL CALLBACK EnumerateOne(HWND hwnd, LPARAM parameter) {
  auto& state = *reinterpret_cast<Enumeration*>(parameter);
  DWORD pid = 0; GetWindowThreadProcessId(hwnd, &pid);
  Handle process; process.value = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  // A window whose process cannot be opened cannot become a candidate. The interactive desktop is
  // enumerated whenever the launch has no private desktop, and one unopenable foreign window there
  // must not fail the whole inventory; candidates stay restricted to processes inside our job.
  if (!process.value) return TRUE;
  BOOL owned = FALSE;
  if (!IsProcessInJob(process.value, state.job, &owned)) { state.failed = true; return FALSE; }
  if (!owned || !IsWindowVisible(hwnd)) return TRUE;
  RECT rect{};
  if (!GetClientRect(hwnd, &rect)) { state.failed = true; return FALSE; }
  if (rect.right <= rect.left || rect.bottom <= rect.top) return TRUE;
  ProcessIdentity identity;
  if (!ReadProcessIdentity(pid, &identity)) { state.failed = true; return FALSE; }
  state.rows.push_back({hwnd, identity});
  if (state.rows.size() > 32) { state.failed = true; return FALSE; }
  return TRUE;
}
std::vector<Candidate> Inventory(HANDLE job, HDESK desktop) {
  Enumeration state{job, false, {}};
  Require(EnumDesktopWindows(desktop, EnumerateOne, reinterpret_cast<LPARAM>(&state)) && !state.failed,
          "REGISTRATION_INVENTORY_FAILED");
  Require(!state.rows.empty(), "REGISTRATION_NO_CANDIDATES");
  std::sort(state.rows.begin(), state.rows.end(), [](const auto& a, const auto& b) {
    return reinterpret_cast<ULONG_PTR>(a.hwnd) < reinterpret_cast<ULONG_PTR>(b.hwnd);
  });
  return state.rows;
}
bool Same(const std::vector<Candidate>& a, const std::vector<Candidate>& b) {
  if (a.size() != b.size()) return false;
  for (size_t i = 0; i < a.size(); ++i)
    if (a[i].hwnd != b[i].hwnd || a[i].owner.Key() != b[i].owner.Key()) return false;
  return true;
}
JsonObject Identity(const Candidate& row) {
  return JsonObject().Str("hwnd", HwndKey(row.hwnd)).Uint("pid", row.owner.pid)
    .Str("processIdentity", row.owner.Key());
}
std::string InventoryJson(const std::vector<Candidate>& rows) {
  std::string result = "[";
  for (const auto& row : rows) { if (result.size() > 1) result += ','; result += Identity(row).Build(); }
  return result + ']';
}
bool Color(const BYTE* data, unsigned pitch, unsigned width, unsigned height,
           int x, int y, int r, int g, int b) {
  if (x < 0 || y < 0 || static_cast<unsigned>(x) >= width || static_cast<unsigned>(y) >= height) return false;
  auto p = data + static_cast<size_t>(y) * pitch + static_cast<size_t>(x) * 4;
  return p[3] == 255 && (r==255 && g==0 && b==255 ? p[0]==255 && p[1]==0 && p[2]==255 : abs(p[0] - b) <= 8 && abs(p[1] - g) <= 8 && abs(p[2] - r) <= 8);
}
// The captured window is not 1:1 with the client's GUI space: a measured desktop
// capture rendered one authored 8-pixel cell as 11.44 physical pixels, which the
// fixed-pitch reader could never decode. The lattice is therefore measured from the
// rendered magenta ring inside the contract below. An occluded or truncated border
// measures short and is refused rather than decoded from its remainder, and a cell
// size outside the contract is refused rather than guessed.
constexpr unsigned kMarkerColumns = 18, kMarkerRows = 10;
constexpr unsigned kMinCellPixels = 8, kMaxCellPixels = 32;
std::string Search(const BYTE* data, unsigned pitch, unsigned width, unsigned height,
                   const std::vector<std::string>& /*wanted*/) {
  std::string result = "["; unsigned count = 0;
  auto magenta = [&](long long px, long long py) {
    return px >= 0 && py >= 0 && px < static_cast<long long>(width) && py < static_cast<long long>(height)
      && Color(data,pitch,width,height,static_cast<int>(px),static_cast<int>(py),255,0,255);
  };
  for (unsigned y = 0; y < height; ++y) for (unsigned x = 0; x < width; ++x) {
    if (!magenta(x,y) || magenta(static_cast<long long>(x)-1,y) || magenta(x,static_cast<long long>(y)-1)) continue;
    // Measure the lattice from the ring's top and left borders.
    unsigned across = 0;
    while (magenta(static_cast<long long>(x)+across,y)) ++across;
    unsigned down = 0;
    while (magenta(x,static_cast<long long>(y)+down)) ++down;
    if (across < kMarkerColumns*kMinCellPixels || across > kMarkerColumns*kMaxCellPixels) continue;
    const unsigned expected = kMarkerRows*across/kMarkerColumns;
    if (down > expected ? down-expected > 1 : expected-down > 1) continue;
    // Cell centre in the measured lattice, derived from the rendered span so a
    // fractional cell size samples the middle of the cell it names.
    auto centreX = [&](unsigned column) { return x + (2u*column+1u)*across/(2u*kMarkerColumns); };
    auto centreY = [&](unsigned row) { return y + (2u*row+1u)*down/(2u*kMarkerRows); };
    bool valid = true;
    for (unsigned row = 0; row < kMarkerRows && valid; ++row)
      for (unsigned column = 0; column < kMarkerColumns && valid; ++column) {
        if (row != 0 && row != kMarkerRows-1 && column != 0 && column != kMarkerColumns-1) continue;
        valid = magenta(centreX(column),centreY(row));
      }
    if (!valid) continue;
    const unsigned radius = std::max(1u, across/(4u*kMarkerColumns));
    std::string decoded; unsigned digit = 0;
    for (unsigned bit = 0; bit < 128 && valid; ++bit) {
      const long long cx = centreX(bit%16+1), cy = centreY(bit/16+1);
      int selected = -1;
      for (unsigned dy = 0; dy <= 2u*radius && valid; ++dy) for (unsigned dx = 0; dx <= 2u*radius && valid; ++dx) {
        const long long px = cx + static_cast<long long>(dx) - radius, py = cy + static_cast<long long>(dy) - radius;
        int sample = Color(data,pitch,width,height,static_cast<int>(px),static_cast<int>(py),0,0,0) ? 0 :
          Color(data,pitch,width,height,static_cast<int>(px),static_cast<int>(py),255,255,255) ? 1 : -1;
        valid = sample >= 0 && (selected < 0 || selected == sample); selected = sample;
      }
      if (valid) { digit = digit*2+static_cast<unsigned>(selected); if (bit%4==3) { decoded += "0123456789abcdef"[digit]; digit=0; } }
    }
    if (!valid) continue;
    Require(++count <= 64, "REGISTRATION_TOO_MANY_MARKERS");
    if (result.size()>1) result+=',';
    result += JsonObject().Uint("x",x).Uint("y",y).Str("nonce",decoded).Build();
  }
  return result+']';
}
struct Window {
  Candidate candidate;
  gc::GraphicsCaptureItem item{nullptr};
  gc::Direct3D11CaptureFramePool pool{nullptr};
  gc::GraphicsCaptureSession session{nullptr};
  winrt::event_token frameToken{}, closedToken{};
  std::string observation;
};
struct State {
  std::mutex mutex;
  std::condition_variable changed;
  bool closing=false, pending=false;
  long long frequency=0, barrier=0;
  unsigned round=0;
  std::string failure;
  std::filesystem::path directory;
  std::vector<std::string> wanted;
  winrt::com_ptr<ID3D11Device> device;
  winrt::com_ptr<ID3D11DeviceContext> context;
};
void Frame(const std::shared_ptr<State>& state, const std::shared_ptr<Window>& window,
           const gc::Direct3D11CaptureFramePool& pool) noexcept {
  std::lock_guard<std::mutex> lock(state->mutex);
  if (state->closing) return;
  try {
    auto frame=pool.TryGetNextFrame(); if(!frame) return;
    const long long stamp=frame.SystemRelativeTime().count();
    Require(stamp>=0,"REGISTRATION_FRAME_TIME");
    // Quotient/remainder conversion avoids multiplying the uptime by frequency.
    const long long qpc=(stamp/10000000)*state->frequency+(stamp%10000000)*state->frequency/10000000;
    if(!state->pending || !window->observation.empty() || qpc<=state->barrier) { frame.Close(); return; }
    ProcessIdentity owner;
    Require(IdentityStillCurrent(window->candidate.owner) && IdentifyWindowOwner(window->candidate.hwnd,&owner)
      && owner.Key()==window->candidate.owner.Key(),"REGISTRATION_IDENTITY_CHANGED");
    auto access=frame.Surface().as<Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess>();
    winrt::com_ptr<ID3D11Texture2D> texture;
    winrt::check_hresult(access->GetInterface(IID_PPV_ARGS(texture.put())));
    D3D11_TEXTURE2D_DESC desc{};texture->GetDesc(&desc);
    Require(desc.Width && desc.Height && static_cast<unsigned long long>(desc.Width)*desc.Height<=16777216
      && desc.Format==DXGI_FORMAT_B8G8R8A8_UNORM,"REGISTRATION_FRAME_FORMAT");
    auto stagingDesc=desc;stagingDesc.Usage=D3D11_USAGE_STAGING;stagingDesc.BindFlags=0;
    stagingDesc.CPUAccessFlags=D3D11_CPU_ACCESS_READ;stagingDesc.MiscFlags=0;
    winrt::com_ptr<ID3D11Texture2D> staging;
    winrt::check_hresult(state->device->CreateTexture2D(&stagingDesc,nullptr,staging.put()));
    state->context->CopyResource(staging.get(),texture.get());
    D3D11_MAPPED_SUBRESOURCE mapped{};
    winrt::check_hresult(state->context->Map(staging.get(),0,D3D11_MAP_READ,0,&mapped));
    std::string matches;
    const auto path=state->directory/(L"round-"+std::to_wstring(state->round)+L"-"+
      std::to_wstring(reinterpret_cast<ULONG_PTR>(window->candidate.hwnd))+L".bgra");
    try {
      matches=Search(static_cast<const BYTE*>(mapped.pData),mapped.RowPitch,desc.Width,desc.Height,state->wanted);
      Handle file;file.value=CreateFileW(path.c_str(),GENERIC_WRITE,0,nullptr,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,nullptr);
      Require(file.value!=INVALID_HANDLE_VALUE,"REGISTRATION_FRAME_CREATE_FAILED");
      for(unsigned y=0;y<desc.Height;++y) {
        DWORD written=0;Require(WriteFile(file.value,static_cast<const BYTE*>(mapped.pData)+static_cast<size_t>(y)*mapped.RowPitch,
          desc.Width*4,&written,nullptr) && written==desc.Width*4,"REGISTRATION_FRAME_WRITE_FAILED");
      }
      Require(FlushFileBuffers(file.value),"REGISTRATION_FRAME_FLUSH_FAILED");
    } catch(...) {state->context->Unmap(staging.get(),0);throw;}
    state->context->Unmap(staging.get(),0);
    window->observation=Identity(window->candidate).Str("path",WideToUtf8(path.wstring()))
      .Uint("width",desc.Width).Uint("height",desc.Height).Uint("stride",desc.Width*4)
      .Str("frameQpc",std::to_string(qpc)).Str("systemRelative100ns",std::to_string(stamp)).Raw("matches",matches).Build();
    frame.Close();state->changed.notify_all();
  } catch(...) {state->failure="REGISTRATION_FRAME_FAILED";state->changed.notify_all();}
}
class Registration {
 public:
  Registration(HANDLE job,HDESK desktop,const std::filesystem::path& directory):job_(job),desktop_(desktop),state_(std::make_shared<State>()) {
    state_->directory=directory;LARGE_INTEGER frequency{};
    Require(QueryPerformanceFrequency(&frequency) && frequency.QuadPart>0 && frequency.QuadPart<=1000000000,"REGISTRATION_QPC_FREQUENCY");
    state_->frequency=frequency.QuadPart;inventory_=Inventory(job_,desktop_);
    try {
      winrt::check_hresult(D3D11CreateDevice(nullptr,D3D_DRIVER_TYPE_HARDWARE,nullptr,D3D11_CREATE_DEVICE_BGRA_SUPPORT,
        nullptr,0,D3D11_SDK_VERSION,state_->device.put(),nullptr,state_->context.put()));
      auto dxgi=state_->device.as<IDXGIDevice>();winrt::com_ptr<IInspectable> wrapped;
      winrt::check_hresult(CreateDirect3D11DeviceFromDXGIDevice(dxgi.get(),wrapped.put()));
      auto d3d=wrapped.as<d3::IDirect3DDevice>();
      auto interop=winrt::get_activation_factory<gc::GraphicsCaptureItem,IGraphicsCaptureItemInterop>();
      for(const auto& candidate:inventory_) {
        auto window=std::make_shared<Window>();window->candidate=candidate;windows_.push_back(window);
        winrt::check_hresult(interop->CreateForWindow(candidate.hwnd,winrt::guid_of<gc::GraphicsCaptureItem>(),reinterpret_cast<void**>(winrt::put_abi(window->item))));
        auto size=window->item.Size();Require(size.Width>0 && size.Height>0 && static_cast<unsigned long long>(size.Width)*size.Height<=16777216,"REGISTRATION_SIZE");
        window->pool=gc::Direct3D11CaptureFramePool::CreateFreeThreaded(d3d,dx::DirectXPixelFormat::B8G8R8A8UIntNormalized,2,size);
        auto state=state_;
        window->frameToken=window->pool.FrameArrived([state,window](auto const& pool,auto const&){Frame(state,window,pool);});
        window->closedToken=window->item.Closed([state](auto const&,auto const&){std::lock_guard<std::mutex> lock(state->mutex);state->failure="REGISTRATION_WINDOW_CLOSED";state->changed.notify_all();});
        window->session=window->pool.CreateCaptureSession(window->item);
      }
      for(auto& window:windows_)window->session.StartCapture();
    } catch(...) {Close();throw;}
  }
  ~Registration(){Close();}
  std::string InventoryText()const{return InventoryJson(inventory_);}
  void Arm(unsigned round,const std::string& nonce) {
    Require(round==3 || round==last_+1,"REGISTRATION_ROUND_ORDER");
    Require(round<=3 && !used_[round],"REGISTRATION_ROUND_REPLAY");
    if(round<3){Require(Nonce(nonce) && (round!=2 || nonce!=nonces_[0]),"REGISTRATION_NONCE_INVALID");nonces_[round-1]=nonce;}
    else Require(nonce=="remove","REGISTRATION_COMMAND");
    Require(Same(inventory_,Inventory(job_,desktop_)),"REGISTRATION_SCOPE_CHANGED");
    std::lock_guard<std::mutex> lock(state_->mutex);Require(!state_->pending,"REGISTRATION_ROUND_ACTIVE");
    used_[round]=true;armed_=round;state_->failure.clear();
    state_->wanted.clear();if(round<3)state_->wanted.push_back(nonce);else for(auto& n:nonces_)if(!n.empty())state_->wanted.push_back(n);
    Emit(JsonObject().Str("type","armed").Uint("round",round).Str("armedQpc",std::to_string(Now())));
  }
  void Snapshot(unsigned round) {
    Require(round==armed_ && round!=last_,"REGISTRATION_ROUND_ORDER");
    Require(Same(inventory_,Inventory(job_,desktop_)),"REGISTRATION_SCOPE_CHANGED");
    std::unique_lock<std::mutex> lock(state_->mutex);state_->round=round;state_->barrier=Now();
    for(auto& window:windows_)window->observation.clear();state_->pending=true;
    bool complete=state_->changed.wait_for(lock,std::chrono::seconds(10),[&]{return !state_->failure.empty() || std::all_of(windows_.begin(),windows_.end(),[](auto& w){return !w->observation.empty();});});
    state_->pending=false;Require(complete,"REGISTRATION_FRAME_TIMEOUT");Require(state_->failure.empty(),"REGISTRATION_FRAME_FAILED");
    lock.unlock();Require(Same(inventory_,Inventory(job_,desktop_)),"REGISTRATION_SCOPE_CHANGED");lock.lock();
    std::string observations="[";for(auto& w:windows_){if(observations.size()>1)observations+=',';observations+=w->observation;}
    observations+=']';last_=round;
    Emit(JsonObject().Str("type","frames").Uint("round",round).Str("barrierQpc",std::to_string(state_->barrier))
      .Str("frequency",std::to_string(state_->frequency)).Raw("observations",observations));
  }
  bool Close() noexcept {
    {std::lock_guard<std::mutex> lock(state_->mutex);if(state_->closing)return closedOk_;state_->closing=true;state_->pending=false;}
    bool ok=true;
    for(auto& w:windows_){try{if(w->pool)w->pool.FrameArrived(w->frameToken);if(w->item)w->item.Closed(w->closedToken);if(w->session)w->session.Close();if(w->pool)w->pool.Close();}catch(...){ok=false;}}
    // Dispatched handlers retain shared ownership of state/window. Their first
    // mutex check observes closing; no raw callback target can be freed early.
    {std::lock_guard<std::mutex> lock(state_->mutex);closedOk_=ok;}
    return ok;
  }
 private:
  HANDLE job_;HDESK desktop_;std::shared_ptr<State> state_;std::vector<Candidate> inventory_;
  std::vector<std::shared_ptr<Window>> windows_;std::string nonces_[2];bool used_[4]={};
  unsigned armed_=0,last_=0;bool closedOk_=false;
};
}
int wmain(int argc,wchar_t** argv) {
  try {
    Require(argc==4,"REGISTRATION_ARGUMENTS");winrt::init_apartment(winrt::apartment_type::multi_threaded);
    Handle job;job.value=OpenJobObjectW(JOB_OBJECT_QUERY,FALSE,argv[1]);
    Desktop desktop;
    // An empty name means the launch had no private desktop: the interactive mode, the only one in
    // which this Studio build registers its MCP server. Enumerate the calling thread's own desktop
    // instead; the job filter below still decides which windows can be candidates.
    if(argv[2][0]==L'\0'){desktop.value=GetThreadDesktop(GetCurrentThreadId());}
    else{desktop.value=OpenDesktopW(argv[2],0,FALSE,DESKTOP_READOBJECTS|DESKTOP_ENUMERATE);desktop.owned=true;}
    Require(job.value && desktop.value,"REGISTRATION_SCOPE_UNAVAILABLE");
    Require(std::filesystem::is_directory(argv[3]),"REGISTRATION_OUTPUT_DIRECTORY");
    Registration registration(job.value,desktop.value,std::filesystem::path(argv[3]));
    Emit(JsonObject().Str("type","ready").Str("jobName",WideToUtf8(argv[1])).Str("desktopName",WideToUtf8(argv[2])).Raw("inventory",registration.InventoryText()));
    std::string line;while(std::getline(std::cin,line)) {
      if(line=="close")break;
      try {
        Require(line.size()<=80,"REGISTRATION_COMMAND");std::istringstream input(line);std::string command,nonce,extra;unsigned round=0;
        input>>command>>round;Require(round>=1 && round<=3,"REGISTRATION_COMMAND");
        if(command=="arm"){input>>nonce;Require(!(input>>extra),"REGISTRATION_COMMAND");registration.Arm(round,nonce);}
        else if(command=="snapshot"){Require(!(input>>extra),"REGISTRATION_COMMAND");registration.Snapshot(round);}
        else throw std::runtime_error("REGISTRATION_COMMAND");
      }catch(const std::exception& error){Emit(JsonObject().Str("type","error").Str("code",error.what()));}
    }
    Require(registration.Close(),"REGISTRATION_CLOSE_FAILED");Emit(JsonObject().Str("type","closed"));return 0;
  }catch(const std::exception& error){Emit(JsonObject().Str("type","error").Str("code",error.what()));return 1;}
  catch(...){Emit(JsonObject().Str("type","error").Str("code","REGISTRATION_NATIVE_FAILED"));return 1;}
}
