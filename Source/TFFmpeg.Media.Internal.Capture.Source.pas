unit TFFmpeg.Media.Internal.Capture.Source;

interface

uses
  TFFmpeg.Media.Types,
  TFFmpeg.Media.Control,
  TFFmpeg.Media.Frames,
  TFFmpeg.Media.Devices;

type
  // Open/read/close execute on the worker. Close releases all native resources;
  // subsequent interface destruction must not access that apartment.
  // Implementations must bound empty reads and honor the supplied token.
  IMediaCaptureSource = interface
    ['{2196E3C5-65C7-4367-B8D4-20D48646EE3C}']
    procedure Open(const ASettings: TMediaCaptureSettings; const AToken: IMediaCancellationToken);
    function GetInfo: TMediaInfo;
    function ReadSample(out ASample: IMediaSample): TMediaReadStatus;
    procedure Close;
    property Info: TMediaInfo read GetInfo;
  end;

implementation

end.
