import DownloadMarquis from "./DownloadMarquis";
import GamesSlider from "./GamesSlider";
import Introduce from "./Introduce";
import LeaderBoard from "./LeaderBoard";
import MarquisMobile from "./MarquisMobile";
import PartnershipSection from "./PartnershipSection";
import SignupSection from "./SignupSection";
import "./style.css";
import Technical from "./Technical";

export default function LandingPage() {
  return (
    <div>
      <div className="flex flex-col lg:gap-[200px] gap-20">
        <SignupSection />
        <Introduce />
        <GamesSlider />
        <div>
          <MarquisMobile />
          <LeaderBoard />
          <PartnershipSection />
        </div>
        <DownloadMarquis />
        <Technical />
      </div>
    </div>
  );
}
