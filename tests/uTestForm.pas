unit uTestForm;

interface

uses
  System.Classes, Vcl.Controls, Vcl.Forms, Vcl.StdCtrls, Vcl.ExtCtrls;

type
  TTestForm = class(TForm)
    Panel1: TPanel;
    Button1: TButton;
    Label1: TLabel;
    Panel2: TPanel;
    Memo1: TMemo;
    procedure Button1Click(Sender: TObject);
    procedure Button2Click(Sender: TObject);
  public
    Clicks: Integer;
  end;

implementation

{$R *.dfm}

procedure TTestForm.Button1Click(Sender: TObject);
begin
  Inc(Clicks);
end;

procedure TTestForm.Button2Click(Sender: TObject);
begin
  Dec(Clicks);
end;

end.
