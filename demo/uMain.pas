unit uMain;

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Variants, System.Classes,
  Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.Dialogs, Vcl.StdCtrls, Vcl.ExtCtrls;

type
  TFormMain = class(TForm)
    pnlTopo: TPanel;
    lblTitulo: TLabel;
    btnSegunda: TButton;
    memLog: TMemo;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure btnSegundaClick(Sender: TObject);
  end;

var
  FormMain: TFormMain;

implementation

uses
  HotReload, uSecond;

{$R *.dfm}

procedure TFormMain.FormCreate(Sender: TObject);
begin
  THotReload.OnLog :=
    procedure(const Msg: string)
    begin
      memLog.Lines.Add(FormatDateTime('hh:nn:ss', Now) + '  ' + Msg);
    end;
end;

procedure TFormMain.FormDestroy(Sender: TObject);
begin
  THotReload.OnLog := nil;
end;

procedure TFormMain.btnSegundaClick(Sender: TObject);
begin
  TFormSecond.Create(Application).Show;
end;

end.
