// loads gamelist.xml, for each game entry (favorite)
// - generate shader file for raster games based on vert/horz orientation
// - generate game.ini files for 4-way (sticky diagonal) control
// 
#include <iostream>
#include <fstream>
#include <map>
#include <string>
#include <tuple>
#include <filesystem>
#include <cstdlib>
#include <tinyxml2.h>

using namespace std;
using namespace tinyxml2;
namespace fs = std::filesystem;

// Constants
const string GAME_LIST_PATH = "/opt/retropie/configs/all/emulationstation/gamelists/arcade/gamelist.xml";
const string TEMP_XML_PATH = "/tmp/mame_listxml_temp.xml";
const string SHADER_OUTPUT_DIR = "/opt/retropie/configs/all/retroarch/config/MAME/";
const string INI_OUTPUT_DIR = "/opt/retropie/emulators/mame/ini/";

struct GameInfo
{
    string shortName;
    string displayType;
    string rotation;
    int ways;
};

// Extract the shortname from a ROM path
string getShortName(const string& romPath)
{
    fs::path path(romPath);
    return path.stem().string();
}

// Run mame -listxml and load the result into an XMLDocument
bool getMameXmlForGame(const string& shortName, XMLDocument& doc)
{
    string command = "mame -listxml " + shortName + " > " + TEMP_XML_PATH;
    int result = system(command.c_str());

    if (result != 0)
    {
        cerr << "Failed to run command: " << command << endl;
        return false;
    }

    return doc.LoadFile(TEMP_XML_PATH.c_str()) == XML_SUCCESS;
}

// Extract display type, rotation, and joystick ways from the MAME XML
bool extractGameInfo(XMLDocument& doc, const string& shortName, GameInfo& info)
{
    info.shortName = shortName;
    info.displayType = "unknown";
    info.rotation = "unknown";
    info.ways = -1;

    XMLElement* machine = doc.FirstChildElement("mame") ?
                          doc.FirstChildElement("mame")->FirstChildElement("machine") :
                          nullptr;

    if (!machine)
    {
        cerr << "No <machine> element found for " << shortName << endl;
        return false;
    }

    // Display info
    XMLElement* display = machine->FirstChildElement("display");
    while (display)
    {
        const char* tag = display->Attribute("tag");
        if (tag && string(tag) == "screen")
        {
            const char* type = display->Attribute("type");
            const char* rotate = display->Attribute("rotate");

            if (type)    info.displayType = type;
            if (rotate)  info.rotation = rotate;
            break;
        }
        display = display->NextSiblingElement("display");
    }

    // Joystick info
    XMLElement* input = machine->FirstChildElement("input");
    if (input)
    {
        XMLElement* control = input->FirstChildElement("control");
        while (control)
        {
            const char* ctrlType = control->Attribute("type");
            const char* waysAttr = control->Attribute("ways");

            if (ctrlType && string(ctrlType) == "joy" && waysAttr)
            {
                try
                {
                    info.ways = stoi(waysAttr);
                }
                catch (...)
                {
                    cerr << "Invalid 'ways' value for " << shortName << endl;
                }
                break;
            }

            control = control->NextSiblingElement("control");
        }
    }

    return true;
}

// Write shader preset file based on display type and rotation
void writeShaderFile(const GameInfo& info)
{
    if (info.displayType != "raster")
    {
        return;
    }

    string filePath = SHADER_OUTPUT_DIR + info.shortName + ".glslp";
    string line = (info.rotation == "0")
                  ? "#reference \"../../shaders/crt-pi.glslp\""
                  : "#reference \"../../shaders/crt-pi-vertical.glslp\"";

    ofstream out(filePath);
    if (!out)
    {
        cerr << "Failed to write shader file: " << filePath << endl;
        return;
    }

    out << line << endl;
    out << "SCANLINE_WEIGHT = \"1.500000\"" << endl;
    out << "SCANLINE_GAP_BRIGHTNESS = \"0.500000\"" << endl;
    out.close();
}

// Write .ini file for joystick mapping if needed
// ref. @ retrogamedeconstructionzone.com/2019/11/joystick-mapping-in-mame.html
void writeJoystickIni(const GameInfo& info)
{
    // Special case: qbert's joystick is physically rotated 45°,
    // so we treat it as an 8-way joystick even though it's defined as 4-way.
    bool isQbert = (info.shortName == "qbert");

    // Special case: defender will have a 2-way joystick with far left/right positions for reverse
    // (a standard 4-way doesn't work well when L/R is defined as reverse)
    bool isDefender = (info.shortName == "defender");

    if ((info.ways == 8 || info.ways == -1) && !isQbert && !isDefender)
    {
        // 8-way joystick or no joystick: no .ini file needed
        return;
    }

    string filePath = INI_OUTPUT_DIR + info.shortName + ".ini";
    string mapLine = "joystick_map s8.4s8.44s8.4445";  // 4-way with sticky diags
    string qbertLn = "joystick_map "    // no symetry: all positions spec'd
                        "4444s8888."    // 4 = left, s = sticky, 8 = up
                        "4444s8888."
                        "444458888."    // 5 = nuetral
                        "444555888."
                        "ss55555ss."
                        "222555666."    // 2 = down, 6 = right
                        "222256666."
                        "2222s6666."
                        "2222s6666";
    string defender = "joystick_map "   // 2-way with far L/R for reverse
                        "s8888888s."
                        "ss88888ss."
                        "4ss888ss6."
                        "445555566."
                        "445555566."
                        "445555566."
                        "4ss222ss6."
                        "ss22222ss."
                        "s2222222s";

    // Check if file exists and if it already contains a joystick map
    if (fs::exists(filePath))
    {
        ifstream in(filePath);
        if (in)
        {
            string line;
            while (getline(in, line))
            {
                if ((line.find("joystick_map") != string::npos) ||
                    (line.find("joymap") != string::npos))
                {
                    // Line already exists, no need to append
                    in.close();
                    return;
                }
            }
            in.close();
        }

        // File exists but doesn't have the line, append it
        ofstream out(filePath, ios::app);
        if (!out)
        {
            cerr << "Failed to append to INI file: " << filePath << endl;
            return;
        }

        if (isDefender)
            out << defender << endl;
        else if (isQbert)
            out << qbertLn << endl;
        else
            out << mapLine << endl;

        out.close();
    }
    else
    {
        // File doesn't exist, create it with the line
        ofstream out(filePath);
        if (!out)
        {
            cerr << "Failed to write INI file: " << filePath << endl;
            return;
        }
        out << (qbert ? qbertLn : mapLine) << endl;
        out.close();
    }
}

int main()
{
    XMLDocument gamelistDoc;

    if (gamelistDoc.LoadFile(GAME_LIST_PATH.c_str()) != XML_SUCCESS)
    {
        cerr << "Failed to load gamelist: " << GAME_LIST_PATH << endl;
        return 1;
    }

    XMLNode* root = gamelistDoc.FirstChildElement("gameList");
    if (!root)
    {
        cerr << "No <gameList> element found." << endl;
        return 1;
    }

    XMLElement* game = root->FirstChildElement("game");

    while (game)
    {
        XMLElement* pathElement = game->FirstChildElement("path");
        if (!pathElement || !pathElement->GetText())
        {
            game = game->NextSiblingElement("game");
            continue;
        }

        string romPath = pathElement->GetText();
        string shortName = getShortName(romPath);

        XMLDocument mameDoc;
        if (!getMameXmlForGame(shortName, mameDoc))
        {
            game = game->NextSiblingElement("game");
            continue;
        }

        GameInfo info;
        if (!extractGameInfo(mameDoc, shortName, info))
        {
            game = game->NextSiblingElement("game");
            continue;
        }

        writeShaderFile(info);
        writeJoystickIni(info);

        // Optional summary output
        cout << "Game: " << info.shortName
             << ", Type: " << info.displayType
             << ", Rotation: " << info.rotation
             << ", Ways: " << (info.ways >= 0 ? to_string(info.ways) : "n/a")
             << endl;

        game = game->NextSiblingElement("game");
    }

    fs::remove(TEMP_XML_PATH);
    return 0;
}
